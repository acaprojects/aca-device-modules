module Planar; end

# Documentation: https://aca.im/driver_docs/Planar/020-1028-00%20RS232%20for%20Matrix.pdf
#  also https://aca.im/driver_docs/Planar/020-0567-05_WallNet_guide.pdf

class Planar::ClarityMatrix
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    implements :device
    descriptive_name 'Planar Clarity Matrix Video Wall'
    generic_name :VideoWall

    # Communication settings
    tokenize delimiter: "\r"
    wait_response false


	def on_load
	end
	
	def on_unload
	end
	
	def on_update
	end

    def connected
        do_poll
        schedule.every('60s') do
            do_poll
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #   Hence the check if timer is nil here
        #
        schedule.clear
    end

    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        options[:wait] = true
        options[:name] = :pwr_query
        send("op A1 display.power ? \r", options)
    end

    def power(state, broadcast_ip = false, options = {})
        power? do
            result = self[:power]

            options[:delay] = 3000
            options[:name] = :power
            if is_affirmative?(state) && result == Off
                send("op ** display.power = on \r", options)
                power?
                schedule.in('20s') do
                    recall(0)
                end
            elsif result == On
                send("op ** display.power = off \r", options)
                power?
            end
        end
    end


    def switch_to(*)
        #send("op A1 slot.recall(0) \r")

        # this is called when we want the whole wall to show the one thing
        # We'll just recall the one preset and have a different function for
        # video wall specific functions
    end

    def recall(preset, options = {})
        options[:name] = :recall
        send("op ** slot.recall (#{preset}) \r", options)
    end


    def input_status(options = {})
        options[:wait] = true
        send("op A1 slot.current ? \r", options)
    end


    def received(data, resolve, command)
        logger.debug "Vid Wall: #{data}"

        data = data.split('.')      # OPA1DISPLAY.POWER=ON || OPA1SLOT.CURRENT=0
        component = data[0]         # OPA1DISPLAY || OPA1SLOT
        data = data[1].split('=')

        status = data[0].downcase.to_sym     # POWER || CURRENT
        value = data[1]             # ON || 0

        case status
        when :power
            self[:power] = value == 'ON'
        when :current
            self[:input] = value.to_i
        end

        return :success
    end


    protected


    def do_poll
        power?({priority: 0}) do
            if self[:power] == On
                input_status priority: 0
            end
        end
    end
end

