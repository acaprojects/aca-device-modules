# encoding: ASCII-8BIT
# frozen_string_literal: true

load File.expand_path('../base.rb', File.dirname(__FILE__))
module Extron::Recorder; end

# documentation: https://aca.im/driver_docs/Extron/extron_smp300_Series.pdf

class Extron::Recorder::SMP300Series < Extron::Base
    # Discovery Information
    descriptive_name 'Extron Recorder SMP 300 Series'
    generic_name :Recorder
    tcp_port 23

    # This should consume the whole copyright message
    tokenize delimiter: "\r\n", wait_ready: /Copyright.*/i

    # NOTE:: The channel arguments are here for compatibility with other recording devices
    def information(channel = 1)
        # Responds with "<ChA1*ChB3>*<stopped>*<internal>*<437342288>*<00:00:00>*<155:40:43>"
        send('I', name: :information, command: :information)
    end

    def record(channel = 1)
        do_send("\eY1RCDR", name: :record_action)
    end

    def stop(channel = 1)
        do_send("\eY0RCDR", name: :record_action)
    end

    def pause(channel = 1)
        do_send("\eY2RCDR", name: :record_action)
    end

    def status(channel = 1)
        do_send("\eYRCDR", name: :status)
    end

    # only works with scheduled recordings
    def extend(minutes, channel = 1)
        do_send("\eE#{minutes}RCDR", name: :extend)
    end

    def add_marker(channel = 1)
        do_send("\eBRCDR")
    end

    def swap_channel_positions(channel = 1)
        send('%', name: :swap)
        information
    end

    def recording_duration
        send('35I', name: :duration)
    end

    def do_poll
        information
        status
    end

    protected

    def received(data, resolve, command)
        data = data.strip
        logger.debug { "Extron Recorder sent #{data.inspect}" }

        if data =~ /Login/i
            device_ready
            return :success
        end

        if data[0] == '<'
            parts = data[1..-2].split('>*<')
            self[:recording_channels] = parts[1]
            self[:recording_to] = parts[2]
            self[:time_remaining] = parts[-1]
            self[:recording_time] = parts[-2]
            self[:free_space] = parts[-3]
        elsif data.start_with? 'RcdrY'
            self[:channel1] = case data[-1].to_i
            when 0
                clear_recording_poller
                :idle
            when 1
                if @recording.nil?
                    @recording = schedule.every(1000) { recording_duration }
                end
                :recording
            when 2
                clear_recording_poller
                :paused
            end
        elsif data.start_with? 'Inf35'
            self[:duration] = data.split('*')[1]
        end

        :success
    end

    def clear_recording_poller
        if @recording
            @recording.cancel
            @recording = nil
            self[:duration] = '00:00:00'
        end
    end
end
