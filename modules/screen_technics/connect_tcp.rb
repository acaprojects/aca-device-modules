module ScreenTechnics; end

# Documentation: https://aca.im/driver_docs/Screen%20Technics/Screen%20Technics%20IP%20Connect%20module.pdf
# Default user: Admin
# Default pass: Connect

class ScreenTechnics::ConnectTcp
    include ::Orchestrator::Constants


    # Discovery Information
    descriptive_name 'Screen Technics Projector Screen Control (Raw TCP)'
    generic_name :Screen

    # Communication settings
    delay between_sends: 500, on_receive: 120
    tcp_port 3001
    tokenize delimiter: "\r\n"
    clear_queue_on_disconnect!


    Commands = {
        up: 30,
        down: 33,
        status: 1,  # this differs from the doc, but appears to work
        stop: 36
    }
    Commands.merge!(Commands.invert)


    def on_load
        on_update
    end

    def on_update
        @count = setting(:screen_count) || 1
    end

    def connected
        (1..@count).each { |index| query_state(index) }
        schedule.every('15s') {
            (1..@count).each { |index| query_state(index) }
        }
    end

    def disconnected
        schedule.clear
    end

    def state(new_state, index = 1)
        if is_affirmative?(new_state)
            down(index)
        else
            up(index)
        end
    end

    def down(index = 1)
        return if down?
        stop(index)
        do_send :down, index, name: :direction
        query_state(index)
    end

    def down?(index = 1)
        down_states = [:moving_bottom, :at_bottom]
        down_states.include?(self[:"screen#{index}"])
    end

    def up(index = 1)
        return if up?
        stop(index)
        do_send :up, index, name: :direction
        query_state(index)
    end

    def up?(index = 1)
        up_states = [:moving_top, :at_top]
        up_states.include?(self[:"screen#{index}"])
    end

    def stop(index = 1, emergency = false)
        options = {
            name: :stop,
            priority: 99
        }
        options[:clear_queue] = :true if emergency

        do_send :stop, index, options
        query_state(index)
    end

    STATUS_REGISTER = 0x20
    def query_state(index = 1)
        do_send :status, index, STATUS_REGISTER
    end


    protected


    Status = {
        0 => :moving_top,
        1 => :moving_bottom,
        2 => :moving_preset_1,
        3 => :moving_preset_2,
        4 => :moving_top,       # preset top
        5 => :moving_bottom,    # preset bottom
        6 => :at_top,
        7 => :at_bottom,
        8 => :at_preset_1,
        9 => :at_preset_2,
        10 => :stopped,
        11 => :error,
        # 12 => undefined
        13 => :error_timeout,
        14 => :error_current,
        15 => :error_rattle,
        16 => :at_bottom   # preset bottom
    }

    def received(data, resolve, command)
        logger.debug { "Screen sent #{data}" }

        # Builds an array of numbers from the returned string
        parts = data.split(/,/).map { |part| part.strip.to_i }
        cmd = Commands[parts[0] - 100]

        if cmd
            index = parts[2] - 16

            case cmd
            when :up
                logger.debug { "Screen#{index} moving up" }
            when :down
                logger.debug { "Screen#{index} moving down" }
            when :stop
                logger.debug { "Screen#{index} stopped" }
            when :status
                self[:"screen#{index}"] = Status[parts[-1]]
            end
            :success
        else
            logger.debug { "Unknown command #{parts[0]}" }
            :abort
        end
    end

    def do_send(cmd, index = 1, *args, **options)
        address = index + 16
        options.merge!(args.pop) if args[-1].is_a? Hash
        parts = [Commands[cmd], address] + args
        send "#{parts.join(', ')}\r\n", options
    end
end
