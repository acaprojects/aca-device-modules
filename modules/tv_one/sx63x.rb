module TvOne; end

# Documentation: https://aca.im/driver_docs/TV%20One/SX-632-634.pdf

class TvOne::Sx63x
    include ::Orchestrator::Constants

    descriptive_name 'TV One T1-SX HDMI Switcher'
    generic_name :Switcher
    implements   :device

    wait_response false
    delay between_sends: 200


    def on_load
        on_update
    end

    def on_update
        @buffer ||= ''
    end

    def connected
        schedule.every('60s') do
            logger.debug "Ensuring TVOne switcher is on"
            power true
        end
    end
    
    def disconnected
        schedule.clear
    end

    def power(state)
        if is_affirmative?(state)
            send 'P1'
        else
            send 'P0'
        end
    end

    def switch_to(input)
        send "I#{input}"
    end

    def switch(map)
        map.each do |input|
            switch_to input
        end
    end


    def received(data, resolve, command)
        @buffer << data

        if @buffer.length > 1
            data = @buffer
            @buffer = ''
        else
            return
        end

        logger.debug { "TV One Switcher sent #{data}" }

        case data[0]
        when 'P'
            self[:power] = data[1] == '1'
        when 'I'
            self[:input] = data[1].to_i
        when 'S'
            self[:enhance] = data[1] == '1'
        else
            logger.info "Unknown response #{data}"
        end

        return :success
    end
end
