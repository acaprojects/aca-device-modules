load File.expand_path('../base.rb', File.dirname(__FILE__))
module Extron::Mixer; end


# Documentation: https://aca.im/driver_docs/Extron/Extron%20DMP64%20DSP.pdf
#
# Volume outputs
# 60000 == volume 1
# 60003 == volume 4
#
# Pre-mix gain inputs
# 40100 == Mic1
# 40105 == Mic6

#
# DsG60003*01048 min vol
# DsG60003*02048
#


class Extron::Mixer::Dmp64 < Extron::Base
    descriptive_name 'Extron DSP DMP64'
    generic_name :Mixer

    def on_load
        #
        # Setup constants
        #
        self[:output_volume_max] = 2168
        self[:output_volume_min] = 1048
        self[:mic_gain_max] = 2298
        self[:mic_gain_min] = 1698
        on_update
    end

    def on_update
        @mute_indicator, @fader_indicator, @fader_type = setting(:fader_type) || ['D', 'D', 'GRPM']
    end

    def call_preset(number)
        if number < 0 || number > 32
            number = 0    # Current configuration
        end
        send("#{number}.")    # No Carriage return for presents
        # Response: Rpr#{number}
    end
    alias_method :preset, :call_preset
    alias_method :trigger, :call_preset

    #
    # Input control
    #
    def adjust_gain(mic, value)    # \e == 0x1B == ESC key
        do_send("\eG4010#{mic}*#{value}AU")
        # Response: DsG4010#{mic}*#{value}
    end

    def adjust_gain_relative(mic, value)    # \e == 0x1B == ESC key
        current = do_send("\eG4010#{mic}AU")
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
            do_send("\e#{@mute_indicator}#{fad}*#{val}#{@fader_type}", group_type: :mute, wait: true)
        end
        # Response:  GrpmD#{group}*+00001
    end
    # Named params version
    def mutes(ids:, muted: true, **_)
        mute(ids, muted)
    end

    def unmute(group, index = nil)
        mute(group, false, index)
        #do_send("\eD#{group}*0GRPM", :group_type => :mute)
        # Response:  GrpmD#{group}*+00000
    end

    def fader(group, value, type = :group)    # \e == 0x1B == ESC key
        faders = group.is_a?(Array) ? group : [group]
        faders.each do |fad|
            do_send("\e#{@fader_indicator}#{fad}*#{value}#{@fader_type}", group_type: :volume, wait: true)
        end

        # Response: GrpmD#{group}*#{value}*GRPM
    end
    # Named params version
    def faders(ids:, level:, index: :group, **_)
        fader(ids, level, index)
    end

    def fader_status(group, type = :group)
        do_send("\e#{@fader_indicator}#{group}#{@fader_type}", group_type: type, wait: true)
    end


    # For inter-module compatibility
    def query_fader(fader_id)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        fader_status(fad, :volume)
    end
    # Named params version
    def query_faders(ids:, **_)
        query_fader(ids)
    end


    def query_mute(fader_id)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        fader_status(fad, :mute)
    end
    # Named params version
    def query_mutes(ids:, **_)
        query_mute(ids)
    end



    def fader_relative(group, value)    # \e == 0x1B == ESC key
        if value < 0
            value = -value
            do_send("\eD#{group}*#{value}-GRPM")
        else
            do_send("\eD#{group}*#{value}+GRPM")
        end
        # Response: GrpmD#{group}*#{value}*GRPM
    end

    #
    # Sends copyright information
    # Then sends password prompt
    #
    def received(data, resolve, command)
        logger.debug { "Extron DSP sent #{data}" }

        if data =~ /Login/i
            device_ready
        else
            cmd = data[0..2].to_sym

            case cmd
            when :Grp, :DsG    # Mute or Volume
                data = data.split('*')
                if command.present? && command[:group_type] == :mute
                    self["fader#{data[0][5..-1].to_i}_mute"] = data[1][-1] == '1'    # 1 == true
                elsif command.present? && command[:group_type] == :volume
                    self["fader#{data[0][5..-1].to_i}"] = data[1].to_i
                else
                    logger.debug { "DSP response failure as couldn't determine if mute or volume request" }
                    return :ignore
                end
            #when :DsG    # Mic gain
            #   self["mic#{data[7]}_gain"] = data[9..-1].to_i
            when :DsM    # Mic Mute
                self["mic#{data[7]}_mute"] = data[-1] == '1'    # 1 == true
            when :Rpr    # Preset called
                logger.debug "Extron DSP called preset #{data[3..-1]}"
            when :Ver
                return :success
            else
                if data == 'E22'    # Busy! We should retry this one
                    command[:delay_on_receive] = 1 unless command.nil?
                    return :failed
                elsif data[0] == 'E'
                    logger.info "Extron Error #{ERRORS[data[1..2].to_i]}"
                    logger.info "- for command #{command[:data]}" unless command.nil?
                else
                    logger.info "unknown response type #{cmd} for response #{data}"
                    logger.info "possibly requested with #{command[:data]}" unless command.nil?
                    return :ignore
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
