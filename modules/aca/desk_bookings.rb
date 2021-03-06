# frozen_string_literal: true

module Aca; end
class ::Aca::DeskBookings
    include ::Orchestrator::Constants

    descriptive_name 'ACA Desk Bookings Logic'
    generic_name :DeskBookings
    implements :logic

    default_settings({
        autocheckin_window: "1h",
        cancel_bookings_after: "0s",
        check_autocancel_every: "5m",
        send_email_invites: false,
        zone_to_desk_ids: {
            "zone-xxx" => ["desk-01.001", "desk-01.002"],
            "zone-yyy" => ["desk-02.001", "desk-02.002"]
        }
    })

    def on_load
        system.load_complete do
            begin
                @status = {}
                on_update
            rescue => e
                logger.print_error e
            end
        end
    end

    def on_update
        @autocheckin_window = UV::Scheduler.parse_duration(setting('autocheckin_period')    || '0s') / 1000  # convert '1m2s' to '62'
        @autocancel_delay   = UV::Scheduler.parse_duration(setting('cancel_bookings_after') || '0s') / 1000
        @autocancel_scan_interval = setting('check_autocancel_every')

        # local timezone of all the desks served by this logic (usually, all the desks in this building)
        @tz = setting('timezone') || ENV['TZ']

        @zone_of = {}
        saved_status    = setting('status') || {}
        @zones_to_desks = setting('zone_to_desk_ids') || {}
        @zones_to_desks.each do |zone, desks|
            # load and expose previously saved status if there is no current status.
            @status[zone] ||= saved_status[zone] || {}
            desks.each do |desk|
                @zone_of[desk] = zone       # create reverse lookup: desk => zone
                @status[zone][desk] ||= {}  # init all known desk ids without overwriting existing bookings
            end
            expose_status(zone)
        end

        @email_enabled = setting('send_email_invites')
        if @email_enabled
            msgraph_client_id  = setting(:msgraph_client_id)  || setting(:office_client_id)
            msgraph_secret     = setting(:msgraph_secret)     || setting(:office_secret)
            msgraph_token_path = setting(:msgraph_token_path) || setting(:office_token_path) || "/oauth2/v2.0/token"
            msgraph_token_url  = setting(:msgraph_token_url)  || setting(:office_token_url)  || "/" + setting(:msgraph_tenant) + msgraph_token_path
            msgraph_https_proxy = setting(:msgraph_https_proxy)
            @desks_mailbox = (setting(:msgraph_mailbox) || system.email)

            @msgraph = ::Microsoft::Office2::Client.new({
                client_id:                  msgraph_client_id,
                client_secret:              msgraph_secret,
                app_token_url:              msgraph_token_url,
                https_proxy:                msgraph_https_proxy
            })
        end

        schedule.clear
        schedule.every(@autocancel_scan_interval) { autocancel_bookings } if @autocancel_delay && @autocancel_scan_interval
    end

    # @param desk_id [String] the unique id that represents a desk
    def desk_details(*desk_ids)
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')    #e.g. 2020-12-31 in local time of the desk
        desk_ids.map { |desk| @status&.dig(@zone_of[desk], desk, todays_date)&.first }
    end

    def book(desk_id, start_epoch, end_epoch = nil)
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')    #e.g. 2020-12-31 in local time of the desk
        start_time   = Time.at(start_epoch).in_time_zone(@tz)
        booking_date = start_time.strftime('%F')
        end_epoch  ||= start_time.midnight.tomorrow.to_i
        zone = @zone_of[desk_id]

        new_booking = {    
            start:      start_epoch, 
            end:        end_epoch - 1,
            checked_in: (start_epoch - Time.now.to_i) < @autocheckin_window,  # No need to check in to bookings that start very soon
            name:       current_user.name
        }
        @status[zone][desk_id] ||= {} 
        @status[zone][desk_id][booking_date] ||= {}
        if @status[zone][desk_id][booking_date].present?
            existing_bookings = @status[zone][desk_id][booking_date]
            existing_bookings.each do |existing_booking_owner, existing_booking|
                # check for clash
                if new_booking[:end] >= existing_booking[:start] && new_booking[:start] <= existing_booking[:end]
                    raise "400 Error: Clashing booking at #{Time.at(existing_booking[:start]).strftime('%T%:z')} - #{Time.at(existing_booking[:end]).strftime('%T%:z')}"
                end
            end
        end

        # Email a meeting invite to the booker, so they can see the booked desk in their calendar
        # Store the event ID in our records, so that it can be targetted for deletion later
        new_booking[:event_id] = send_email_invite(desk_id, start_epoch, end_epoch, current_user) if @email_enabled

        @status[zone][desk_id][booking_date][current_user.email] = new_booking    
        expose_status(zone)
        
        # Also store booking in the user object, with additional info
        new_booking[:desk_id] = desk_id
        new_booking[:zone]    = zone
        add_to_schedule(current_user.email, new_booking)
    end

    def cancel(desk_id, start_epoch, event_id = nil)
        booking_date = Time.at(start_epoch).in_time_zone(@tz).strftime('%F')
        zone = @zone_of[desk_id]
        user = current_user.email
        raise "400 Error: No booking on #{booking_date} for #{user} at #{desk_id}" unless @status.dig(zone, desk_id, booking_date, user, :start)

        @status[zone][desk_id][booking_date].delete(user)
        expose_status(zone)
        
        # Also delete booking from user profile (schedule page of Staff App)
        delete_from_schedule(current_user.email, desk_id, start_epoch)

        cancel_email_invite(event_id) if @email_enabled && event_id
    end

    # param checking_in is a bool: true = checkin, false = checkout
    def check_in(desk_id, start_epoch, checking_in)
        zone = @zone_of[desk_id]
        user = current_user.email
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')
        booking = @status.dig(zone,desk_id,todays_date,user)
        raise "400 Error: No booking on #{todays_date} for #{user} at #{desk_id}" unless booking.present?
        if checking_in
            # Mark as checked_in on this logic
            @status[zone][desk_id][todays_date][user][:checked_in] = true
            # Mark as checked_in on the user profile
            user = get_user(current_user.email)
            user.desk_bookings.each_with_index do |b, i|
                    next unless b[:start] == start_epoch && b[:desk_id] == desk_id
                    user.desk_bookings[i][:checked_in] = true
            end
            user.desk_bookings_will_change!
            user.save!
        else
            delete_from_schedule(current_user.email, desk_id, start_epoch)
            @status[zone][desk_id][todays_date].delete(user)
        end
        expose_status(zone)
    end


    protected

    def expose_status(zone, save_status = true)
        self[zone] = @status[zone].deep_dup
        signal_status(zone)
        define_setting(:status, @status) if save_status   # Also persist new status to DB
    end

    def send_email_invite(desk_id, start_epoch, end_epoch, recipient)
        pretty_time = Time.at(start_epoch).in_time_zone(@tz).strftime('%D%l:%M%P') # e.g. "03/05/20 4:18pm"
        event_request = {
            start_param: start_epoch,
            end_param: end_epoch,
            mailbox: @desks_mailbox,
            options: {
                subject: "Desk #{desk_id} Booked",
                description: "#{desk_id} booked from #{pretty_time}\nPlease arrive on time and scan the QR code with your mobile device to check in.",
                attendees: [recipient],
                location: desk_id,
                timezone: @tz,
                showAs: 'free',
                responseRequested: false
            }
        }
        event = @msgraph.create_booking(event_request)
        logger.debug event.inspect
        return event['id']
    end

    def cancel_email_invite(event_id)
        @msgraph.delete_booking(mailbox: @desks_mailbox, booking_id: event_id)
    end

    def autocancel_bookings
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')
        now = Time.now

        @status.each do |zone|
            zone.each do |desk|
                desk[todays_date]&.each_with do |user_email, booking|
                    next if booking[checked_in]
                    next unless booking[:start] > now + @autocancel_delay
                    @status[zone][desk_id][todays_date].delete(user)
                    expose_status(zone)

                    next unless ENV['ENGINE_DEFAULT_AUTHORITY_ID']
                    delete_from_schedule(user_email, desk_id, start_epoch)
                    
                    # STUB: Notify user of cancellation by email here
                end
            end
        end
    end

    def add_to_schedule(email, booking)
        user = get_user(email)
        user.desk_bookings << booking
        user.desk_bookings_will_change!
        user.save!
    end
    
    def delete_from_schedule(email, desk_id, start_epoch)
        user = get_user(email)
        user.desk_bookings&.each_with_index do |b, i|
            next unless b[:start] == start_epoch && b[:desk_id] == desk_id
            user.desk_bookings.delete_at(i)
            logger.debug "DELETING DESK BOOKING: #{desk_id} #{start_epoch}"
        end
        user.desk_bookings_will_change!
        user.save!
    end
    
    def get_user(email)
        raise "Environment Variable 'ENGINE_DEFAULT_AUTHORITY_ID' not set " unless ENV['ENGINE_DEFAULT_AUTHORITY_ID']
        user = User.find_by_email(ENV['ENGINE_DEFAULT_AUTHORITY_ID'], email)
    end
end
