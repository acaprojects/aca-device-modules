module ClockAudio; end

# Documentation: https://aca.im/driver_docs/Clock%20Audio/CDT100_Module.axs

class ClockAudio::Cdt100
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    udp_port 49494
    descriptive_name 'Clock Audio CDT100 Microphones'
    generic_name :TableMics


    # Communication settings
    tokenise delimiter: "\r\0"
    delay between_sends: 200


    def on_load
    end

    def on_update
        #@local_address = setting(:server_ip) # || local_address
        #@local_port] = 49494  # TODO:: replace with local_port
    end
    
    def connected
        #start_async
        do_poll
        schedule.every('60s') do
            logger.debug "-- Polling Mics"
            do_poll
        end
    end


    Commands = {
        phantom: 'PP',
        query: 'QUERY',
        set_ch32: 'SCH32',
        get_ch32: 'GCH32',
        set_arm_c: 'SARMC',
        get_arm_c: 'GARMC',
        version: 'VERSION',
        async: 'SASIP',
        input_status: 'BSTATUS',
        led_red: 'R=',
        led_green: 'G=',
        input: 'SC=',
        id: 'ID=',
        address: 'GAS',
        preset_save: 'SAVE',
        preset_load: 'LOAD'
    }
    Commands.merge!(Commands.invert)
    MaxChannels = 4


    def get_version(**options)
        do_send(Commands[:version], **options)
    end

    def set_phantom(index, state, **options)
        val = is_affirmative?(state) ? '1' : '0'
        if index > 0
            do_send(Commands[:phantom], index, val, **options)
        else
            1.upto(MaxChannels) do |chan|
                do_send(Commands[:phantom], chan, val, **options)
            end
        end
    end

    def set_red_led(index, state, **options)
        val = is_affirmative?(state) ? 'R=1' : 'R=0'
        if index > 0
            do_send(Commands[:set_ch32], index, val, **options)
        else
            1.upto(MaxChannels) do |chan|
                do_send(Commands[:set_ch32], chan, val, **options)
            end
        end
    end

    def set_green_led(index, state, **options)
        val = is_affirmative?(state) ? 'G=1' : 'G=0'
        if index > 0
            do_send(Commands[:set_ch32], index, val, **options)
        else
            1.upto(MaxChannels) do |chan|
                do_send(Commands[:set_ch32], chan, val, **options)
            end
        end
    end

    def raise_mics(state, **options)
        val = is_affirmative?(state) ? '1' : '0'
        do_send(Commands[:set_arm_c], val, **options)
    end


    # Only seems to be a single preset??
    def save_preset(number = 0, **options)
        # Number is ignored for now
        do_send(Commands[:preset_save], 0, **options)
    end

    # Only seems to be a single preset??
    def load_preset(number = 0, **options)
        # Number is ignored for now
        do_send(Commands[:preset_load], 0, **options)
    end

    # This lets the devices know which IP and port to respond to
    # God forbid they do any packet inspection. I guess it might be useful in a distributed system
    def start_async
        do_send(Commands[:async], "#{@local_address}:#{@local_port}", **options)
    end


    # Returns the mic power on/off state
    def phantom_on?
        do_send(Commands[:query], priority: 0)
    end

    # Returns the raised/lowered state
    def mics_raised?
        do_send(Commands[:get_arm_c], priority: 0)
    end


  
    def received(data, resolve, command)        # Data is default received as a string
        logger.debug { "sent: #{data}" }

        result = data.split(' ')

        if result[0] == 'ACK'
            case Commands[result[1]]
            when :set_ch32
                # ACK SCH32 1 G=1
                channel = result[2]

                # G= or R=
                led = result[3][0..1]

                # 1 == ON, 0 == OFF
                state = result[3][2..-1].to_i == 1

                # led_red_2 = On
                set_status(led, channel, state)

            when :get_ch32
                # ACK GCH32 CH G=1 1 R=2 1

                # Remove garbage
                result = result[(result.index('CH') + 1)..-1]

                begin
                    item, state = result.shift.split('=')
                    channel = result.shift

                    set_status("#{item}=", channel, state.to_i == 1)
                end while result.length > 1

            when :query
                # ACK QUERY PP1=ON PP2=ON PP3=ON PP4=ON ID=OFF
                result.shift
                result.shift

                while result[0] =~ /^PP/
                    item = result.shift # PP1
                    channel = item[2]
                    state = item[-2..-1] == 'ON'

                    set_status('PP', channel, state)
                end

                self[:id] = result[0][-2..-1] == 'ON'

            when :phantom
                # ACK PP 2 1
                item = result[1] # PP
                channel = result[2]
                state = result[3].to_i == 1

                set_status(item, channel, state)

            when :set_arm_c, :get_arm_c
                # ACK GARMC 1
                self[:raised] = result[2].to_i == 1

            when :address
                # ACK GAS something,with,commas
                self[:address] = result[2]

            when :preset_load
                # Need to run query command here

            end
        elsif result[0] == 'NACK'
            logger.warn {
                msg = "Command failed with response #{data}"
                msg << " for cmd: #{command[:data]}" if command
                msg
            }
            return :abort
        else
            # We shouldn't really make it here
        end

        :success
    end


    def do_poll
        mics_raised?
        phantom_on?
    end


    protected


    def set_status(item, channel, state)
        if channel.to_i == 0
            1.upto(MaxChannels) do |index|
                self["#{Commands[item]}_#{index}"] = state
            end
        else
            self["#{Commands[item]}_#{channel}"] = state
        end
    end

    def do_send(cmd, *args, **options)
        if args.length > 0
            send("#{cmd} #{args.join(' ')}\r", options)
        else
            send("#{cmd}\r", options)
        end
    end
end

