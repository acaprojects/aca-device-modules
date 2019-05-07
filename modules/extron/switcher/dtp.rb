load File.expand_path('../base.rb', File.dirname(__FILE__))
module Extron::Switcher; end


# :title:Extron Digital Matrix Switchers
# NOTE:: Very similar to the XTP!! Update both
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# video_inputs
# video_outputs
# audio_inputs
# audio_outputs
#
# video1 => input (video)
# video2
# video3
# video1_muted => true
#
# audio1 => input
# audio1_muted => true
#
#
# (Settings)
# password
#


class Extron::Switcher::Dtp < Extron::Base
    descriptive_name 'Extron Switcher DTP'
    generic_name :Switcher

    #
    # No need to wait as commands can be chained
    #
    def switch(map)
        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)

            outputs = Array(outputs)
            command = ''
            outputs.each do |output|
                command += "#{input}*#{output}!"
            end
            send(command)
        end
    end

    def switch_video(map)
        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)


            outputs = Array(outputs)
            command = ''
            outputs.each do |output|
                command += "#{input}*#{output}%"
            end
            send(command)
        end
    end

    def switch_audio(map)
        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)

            outputs = Array(outputs)
            command = ''
            outputs.each do |output|
                command += "#{input}*#{output}$"
            end
            send(command)
        end
    end

    def mute_video(outputs)
        outputs = Array(outputs)
        command = ''
        outputs.each do |output|
            command += "#{output}*1B"
        end
        send(command)
    end

    def unmute_video(outputs)
        outputs = Array(outputs)
        command = ''
        outputs.each do |output|
            command += "#{output}*0B"
        end
        send(command)
    end

    def mute_audio(outputs)
        outputs = Array(outputs)
        command = ''
        outputs.each do |output|
            command += "#{output}*1Z"
        end
        send(command)
    end

    def unmute_audio(outputs)
        outputs = Array(outputs)
        command = ''
        outputs.each do |output|
            command += "#{output}*0Z"
        end
        send(command)
    end

    def set_preset(number)
        send("#{number},")
    end

    def recall_preset(number)
        send("#{number}.")
    end




    TYPES = {
        analog: 1,
        digital: 2,
        multi: 3
    }
    def configure_audio(input, type = :analog)
        val = TYPES[type]
        send("\x1BI#{input}*#{val}AFMT\r") if val
    end


    # AUDIO Controls
    #
    # Input control
    #
    def adjust_gain(mic, value)    # \e == 0x1B == ESC key
        do_send("\eG4010#{mic}*#{value}AU")
        # Response: DsG4010#{mic}*#{value}
    end

    def adjust_gain_relative(mic, value)    # \e == 0x1B == ESC key
        current = do_send("\eG4010#{mic}AU", :emit => "mic#{mic}_gain")
        do_send("\eG4010#{mic}*#{current + (value * 10)}AU")

        # Response: DsG4010#{mic}*#{value}
    end

    def mute_mic(mic)
        do_send("\eM4000#{mic}*1AU")    # 4000 (input gain), 4010 (pre-mixer gain)
        # Response: DsM4010#{mic}*1
    end

    def unmute_mic(mic)
        do_send("\eM4000#{mic}*0AU")
        # Response: DsM4010#{mic}*0
    end


    #
    # Output control
    #
    def mute(group, value = true, index = nil)
        group = index if index
        val = is_affirmative?(value) ? 1 : 0

        faders = group.is_a?(Array) ? group : [group]
        faders.each do |fad|
            do_send("\eM#{fad}*#{val}AU", group_type: :mute, wait: true)
        end
        # Response:  GrpmD#{group}*+00001
    end

    def unmute(group, index = nil)
        mute_audio(group, false, index)
        #do_send("\eD#{group}*0GRPM", :group_type => :mute)
        # Response:  GrpmD#{group}*+00000
    end

    def mutes(ids:, muted: true, **_)
        mute(ids, muted)
    end

    def fader(group, value, index = nil)    # \e == 0x1B == ESC key
        faders = group.is_a?(Array) ? group : [group]
        faders.each do |fad|
            do_send("\eG#{fad}*#{value}AU", group_type: :volume, wait: true)
        end
    end

    def faders(ids:, level:, **_)
        fader(ids, level)
    end

    def query_fader(groups, type = :volume)
        Array(groups).each do |group|
            do_send("\eG#{group}AU", group_type: type, wait: true)
        end
    end

    def query_faders(ids:, **_)
        query_fader(ids)
    end

    def query_mute(groups, type = :mute)
        Array(groups).each do |group|
            do_send("\eM#{group}AU", group_type: type, wait: true)
        end
    end

    def query_mutes(ids:, **_)
        query_mute(ids)
    end


    #
    # Sends copyright information
    # Then sends password prompt
    #
    def received(data, resolve, command)
        logger.debug { "Extron Matrix sent #{data}" }

        if data =~ /Login/i
            device_ready
        elsif command.present? && command[:command] == :information
            data = data.split(' ')
            video = data[0][1..-1].split('X')
            self[:video_inputs] = video[0].to_i
            self[:video_outputs] = video[1].to_i

            audio = data[1][1..-1].split('X')
            self[:audio_inputs] = audio[0].to_i
            self[:audio_outputs] = audio[1].to_i
        else
            case data[0..1].to_sym
            when :Am    # Audio mute
                data = data[3..-1].split('*')
                self["audio#{data[0].to_i}_muted"] = data[1] == '1'
            when :Vm    # Video mute
                data = data[3..-1].split('*')
                self["video#{data[0].to_i}_muted"] = data[1] == '1'
            when :In    # Input to all outputs
                data = data[2..-1].split(' ')
                input = data[0].to_i
                if data[1] =~ /(All|RGB|Vid)/
                    for i in 1..self[:video_outputs]
                        self["video#{i}"] = input
                    end
                end
                if data[1] =~ /(All|Aud)/
                    for i in 1..self[:audio_outputs]
                        self["audio#{i}"] = input
                    end
                end
            when :Ou    # Output x to input y
                data = data[3..-1].split(' ')
                output = data[0].to_i
                input = data[1][2..-1].to_i
                if data[2] =~ /(All|RGB|Vid)/
                    self["video#{output}"] = input
                end
                if data[2] =~ /(All|Aud)/
                    self["audio#{output}"] = input
                end
            else
                if data == 'E22'    # Busy! We should retry this one
                    command[:delay_on_receive] = 1 unless command.nil?
                    return :failed
                end


                # Check for Audio responses
                case data[0..2].to_sym
                when :DsM    # Mute
                    data = data.split('*')
                    fader = data[0][3..-1].to_i
                    value = data[1].to_i
                    logger.debug { "fader #{fader} and value #{value}, command present #{command.present?}" }

                    if command.present? && command[:group_type] == :mute
                        self["fader#{fader}_mute"] = value == 1    # 1 == true
                    elsif command.present? && command[:group_type] == :volume
                        self["fader#{fader}"] = value
                    else
                        self["fader#{fader}_mute"] = value == 1    # 1 == true
                    end
                when :DsG    # Gain
                    data = data.split('*')
                    fader = data[0][3..-1].to_i
                    value = data[1].to_i
                    logger.debug { "fader #{fader} and value #{value}, command present #{command.present?}" }

                    if command.present? && command[:group_type] == :mute
                        self["fader#{fader}_mute"] = value == 1    # 1 == true
                    elsif command.present? && command[:group_type] == :volume
                        self["fader#{fader}"] = value
                    else
                        self["fader#{fader}"] = value
                    end
                when :Rpr    # Preset called
                    logger.debug "Extron DSP called preset #{data[3..-1]}"
                else
                    if data == 'E22'    # Busy! We should retry this one
                        command[:delay_on_receive] = 200 unless command.nil?
                        return :failed
                    elsif data[0] == 'E'
                        logger.info "Extron Error #{ERRORS[data[1..2].to_i]}"
                        logger.info "- for command #{command[:data]}" unless command.nil?
                    end
                end
            end
        end

        return :success
    end


    private


    ERRORS = {
        1 => 'Invalid input number (number is too large)',
        12 => 'Invalid port number',
        13 => 'Invalid parameter (number is out of range)',
        14 => 'Not valid for this configuration',
        17 => 'System timed out',
        23 => 'Checksum error (for file uploads)',
        24 => 'Privilege violation',
        25 => 'Device is not present',
        26 => 'Maximum connections exceeded',
        27 => 'Invalid event number',
        28 => 'Bad filename or file not found'
    }
end
