module Philips; end

# Documentation: https://aca.im/driver_docs/Philips/Dynet%20Integrators%20hand%20book%20for%20the%20DNG232%20V2.pdf
#  also https://aca.im/driver_docs/Philips/DyNet%201%20Opcode%20Master%20List%20-%202012-08-29.xls

class Philips::Dynalite
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 50000
    descriptive_name 'Philips Dynalite Lighting'
    generic_name :Lighting

    # Communication settings
    delay between_sends: 40
    wait_response false
    tokenize indicator: "\x1C", msg_length: 7 # length - indicator
    

    def on_load
    end

    def connected
        schedule.every('1m') do
            logger.debug "-- Dynalite Maintaining Connection"
            get_current_preset(1)    # preset for area 1
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        schedule.clear
    end


    #
    # Arguments: preset_number, area_number, fade_time in millisecond
    #    Trigger for CBUS module compatibility
    #
    def trigger(area, number, fade = 1000)
        # 0,1,2,3 then a,b,c,d for 4,5,6,7
        self[:"area#{area}"] = number
        area = area.to_i
        number = number.to_i
        fade = (fade.to_i / 10).to_i

        # No response so we should update status here
        self[:"area#{area}"] = number

        number = number - 1
        bank = number / 8
        number = number - (bank * 8)

        if number > 3
            number = number - 4 + 0x0A
        end
                                                       #high fade   #join (currently all in group)
        command = [0x1c, area & 0xFF, fade & 0xFF, number & 0xFF, (fade >> 8) & 0xFF, bank, 0xFF]

        schedule.in(fade + 200) do
            get_light_level(area)
        end
        do_send(command, {name: :"preset_#{area}_#{number}"})
    end
    # Seems to be an undocument trigger command with opcode 65
    # -- not sure how fade works with it..

    def get_current_preset(area)
        command = [0x1c, area.to_i & 0xFF, 0, 0x63, 0, 0, 0xFF]
        do_send(command)
    end

    def save_preset(area, preset)
        num = preset.to_i - 1
        num = in_range(num, 0xFF, 0)
        command = [0x1c, area.to_i & 0xFF, num, 0x09, 0, 0, 0xFF]
        do_send(command)
    end


    def light_level(area, level, channel = 0xFF, fade = 1000)
        cmd = 0x71

        # Command changes based on the length of the fade time
        if fade <= 25500
            fade = (fade / 100).to_i
        elsif fade < 255000
            cmd = 0x72
            fade = (fade / 1000).to_i
        else
            cmd = 0x73
            fade = in_range((fade / 60000).to_i, 22, 1)
        end

        level = level.to_i
        channel = channel.to_i

        # Ensure status values are valid
        if channel == 0xFF # Area (all channels)
            self[:"area#{area}_level"] = level
        else
            self[:"area#{area}_chan#{channel}_level"] = level
        end

        # Levels
        #0x01 == 100%
        #0xFF == 0%
        level = 0xFF - level          # Inverse
        level = in_range(level, 0xFF, 1)

        command = [0x1c, area.to_i & 0xFF, channel & 0xFF, cmd, level, fade & 0xFF, 0xFF]
        do_send(command, {name: :"level_#{area}_#{channel}"})
    end

    def stop_fading(area, channel = 0xFF)
        command = [0x1c, area.to_i & 0xFF, channel.to_i & 0xFF, 0x76, 0, 0, 0xFF]
        do_send(command, {name: :"level_#{area}_#{channel}"})
    end

    def stop_all_fading(area)
        command = [0x1c, area.to_i & 0xFF, 0, 0x7A, 0, 0, 0xFF]
        do_send(command)
    end


    def get_light_level(area, channel = 0xFF)
                       # area,            channel,            cmd,        join
        do_send([0x1c, area.to_i & 0xFF, channel.to_i & 0xFF, 0x61, 0, 0, 0xFF])
    end


    def increment_area_level(area)
        do_send([0x1c, area.to_i & 0xFF, 0x64, 6, 0, 0, 0xFF])
    end


    def decrement_area_level(area)
        do_send([0x1c, area.to_i & 0xFF, 0x64, 5, 0, 0, 0xFF])
    end


    def unlink_area(area)
               # 0x1c, area, unlink_bitmap, 0x21, unlink_bitmap, unlink_bitmap, join (0xFF)
        do_send([0x1c, area.to_i & 0xFF, 0xFF, 0x21, 0xFF, 0xFF, 0xFF])
    end
    
    
    
    def received(data, resolve, command)
        logger.debug { "received 0x#{byte_to_hex(data)}" }
        
        data = str_to_array(data)

        case data[2]
        # current preset selected response
        when 0, 1, 2, 3, 10, 11, 12, 13

            # 0-3, A-D == preset 1..8
            number = data[2]
            number -= 0x0A + 4 if number > 3

            # Data 4 represets the preset offset or bank
            number += data[4] * 8 + 1
            self[:"area#{data[0]}"] = number

        # alternative preset response
        when 0x62
            self[:"area#{data[0]}"] = data[1] + 1

        # level response (area or channel)
        when 0x60
            level = data[3]
            level = 0 if level <= 1
            level = 0xFF - level  # Inverse

            if data[1] == 0xFF # Area (all channels)
                self[:"area#{data[0]}_level"] = level
            else
                self[:"area#{data[0]}_chan#{data[1]}_level"] = level
            end
        end

        :success
    end
    
    
    protected
    
    
    def do_send(command, options = {})
        #
        # build checksum
        #
        check = 0
        command.each do |byte|
            check = check + byte
        end
        check -= 1
        check = ~check
        check = "%x" % check
        check = check[-2, 2]
        check = check.to_i(16)

        #
        # Add checksum to command
        command << check
        command = array_to_str(command)

        # The block prevents the byte_to_hex code being run when
        # we are not in debug mode
        logger.debug { "sent: 0x#{byte_to_hex(command)}" }
        
        send(command, options)
    end
end

