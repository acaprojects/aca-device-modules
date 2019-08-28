# encoding: ASCII-8BIT
require 'faraday'
require 'uv-rays'
require 'microsoft/officenew'
require 'microsoft/office/client'
Faraday.default_adapter = :libuv

module Aca; end
class Aca::O365BookingPanel
    include ::Orchestrator::Constants
    descriptive_name 'Office365 Room Booking Panel Logic'
    generic_name :Bookings
    implements :logic

    # Constants that the Room Booking Panel UI (ngx-bookings) will use
    RBP_AUTOCANCEL_TRIGGERED  = 'pending timeout'
    RBP_STOP_PRESSED        = 'user cancelled'

    # The room we are interested in
    default_settings({
        update_every: '2m',
        booking_cancel_email_message: 'The Stop button was presseed on the room booking panel',
        booking_timeout_email_message: 'The Start button was not pressed on the room booking panel',
        office_client_id: "enter client ID",
        office_secret: "enter client secret",
        office_token: "tenant_name_or_ID.onMicrosoft.com"
    })

    def on_load
        self[:today] = []
        on_update
    end

    def on_update
        self[:room_name] = setting(:room_name) || system.name
        self[:hide_all] = setting(:hide_all) || false
        self[:touch_enabled] = setting(:touch_enabled) || false
        self[:arrow_direction] = setting(:arrow_direction)
        self[:hearing_assistance] = setting(:hearing_assistance)
        self[:timeline_start] = setting(:timeline_start)
        self[:timeline_end] = setting(:timeline_end)
        self[:description] = setting(:description)
        self[:icon] = setting(:icon)
        self[:control_url] = setting(:booking_control_url) || system.config.support_url

        self[:timeout] = setting(:timeout)
        self[:booking_cancel_timeout] = UV::Scheduler.parse_duration(setting(:booking_cancel_timeout)) / 1000 if setting(:booking_cancel_timeout)   # convert '1m2s' to '62'
        self[:booking_cancel_email_message] = setting(:booking_cancel_email_message)
        self[:booking_timeout_email_message] = setting(:booking_timeout_email_message)
        self[:booking_controls] = setting(:booking_controls)
        self[:booking_catering] = setting(:booking_catering)
        self[:booking_hide_details] = setting(:booking_hide_details)
        self[:booking_hide_availability] = setting(:booking_hide_availability)
        self[:booking_hide_user] = setting(:booking_hide_user)
        self[:booking_hide_modal] = setting(:booking_hide_modal)
        self[:booking_hide_title] = setting(:booking_hide_title)
        self[:booking_hide_description] = setting(:booking_hide_description)
        self[:booking_hide_timeline] = setting(:booking_hide_timeline)
        self[:booking_set_host] = setting(:booking_set_host)
        self[:booking_set_title] = setting(:booking_set_title)
        self[:booking_set_ext] = setting(:booking_set_ext)
        self[:booking_search_user] = setting(:booking_search_user)
        self[:booking_disable_future] = setting(:booking_disable_future)
        self[:booking_min_duration] = setting(:booking_min_duration)
        self[:booking_max_duration] = setting(:booking_max_duration)
        self[:booking_duration_step] = setting(:booking_duration_step)
        self[:booking_endable] = setting(:booking_endable)
        self[:booking_ask_cancel] = setting(:booking_ask_cancel)
        self[:booking_ask_end] = setting(:booking_ask_end)
        self[:booking_default_title] = setting(:booking_default_title) || "On the spot booking"
        self[:booking_select_free] = setting(:booking_select_free)
        self[:booking_hide_all] = setting(:booking_hide_all) || false

        office_client_id  = setting(:office_client_id)  || ENV['OFFICE_CLIENT_ID']
        office_secret     = setting(:office_secret)     || ENV["OFFICE_CLIENT_SECRET"]
        office_token_path = setting(:office_token_path) || "/oauth2/v2.0/token"
        office_token_url  = setting(:office_token_url)  || ENV["OFFICE_TOKEN_URL"]  || "/" + setting(:office_token) + office_token_path
        @office_room = (setting(:office_room) || system.email)
        #office_https_proxy = setting(:office_https_proxy)

        logger.debug "RBP>#{@office_room}>INIT: Instantiating o365 Graph API client"

        @client = ::Microsoft::Officenew::Client.new({
            client_id:                  office_client_id,
            client_secret:              office_secret,
            app_token_url:              office_token_url
        })

        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)

        fetch_bookings
        schedule.clear
        schedule.every(setting(:update_every) || '5m') { fetch_bookings }
    end

    def fetch_bookings(*args)
        response = @client.get_bookings(mailboxes: [@office_room], options: {bookings_from: Time.now.midnight.to_i, bookings_to: Time.now.tomorrow.midnight.to_i}).dig(@office_room, :bookings)
        self[:today] = expose_bookings(response)
    end

    def create_meeting(params)
        required_fields = ["start", "end"]
        check = required_fields - params.keys
        if check != []
            logger.debug "Required fields missing: #{check}"
            raise "Required fields missing: #{check}"
        end

        logger.debug "RBP>#{@office_room}>CREATE>INPUT:\n #{params}"
        begin
            result = @client.create_booking(
                        mailbox:        params.dig(:host, :email) || @office_room, 
                        start_param:    epoch(params[:start]), 
                        end_param:      epoch(params[:end]), 
                        options: {
                            subject:    params[:title] || setting(:booking_default_title),
                            attendees:  [ {email: @office_room, type: "resource"} ],
                            timezone:   ENV['TZ']   
                        }
                    )
        rescue Exception => e
            logger.error "RBP>#{@office_room}>CREATE>ERROR: #{e.message}\n#{e.backtrace.join("\n")}"
            raise e
        else
            logger.debug { "RBP>#{@office_room}>CREATE>SUCCESS:\n #{result}" }
            schedule.in('2s') do
                fetch_bookings
            end
        end
        "Ok"
    end

    def start_meeting(meeting_ref)
        self[:last_meeting_started] = meeting_ref
        self[:meeting_pending] = meeting_ref
        self[:meeting_ending] = false
        self[:meeting_pending_notice] = false
        define_setting(:last_meeting_started, meeting_ref)
    end

    def cancel_meeting(start_time, reason = "unknown reason")
        now = Time.now.to_i
        start_epoch = Time.parse(start_time).to_i
        ms_epoch = start_epoch * 1000
        too_early_to_cancel = now < start_epoch
        too_late_to_cancel = self[:booking_cancel_timeout] ?  (now > (start_epoch + self[:booking_cancel_timeout] + 180)) : false   # "180": allow up to 3mins of slippage, in case endpoint is not NTP synced
        bookings_to_cancel = bookings_with_start_time(start_epoch)

        if bookings_to_cancel > 1
            logger.warn { "RBP>#{@office_room}>CANCEL>CLASH: No bookings cancelled as Multiple bookings (#{bookings_to_cancel}) were found with same start time #{start_time}" } 
            return
        end
        if bookings_to_cancel == 0
            logger.warn { "RBP>#{@office_room}>CANCEL>NOT_FOUND: Could not find booking to cancel with start time #{start_time}" }
            return
        end

        case reason
        when RBP_STOP_PRESSED
            delete_o365_booking(start_epoch, reason)
        when RBP_AUTOCANCEL_TRIGGERED
            if !too_early_to_cancel && !too_late_to_cancel
                delete_o365_booking(start_epoch, reason)
            else
                logger.warn { "RBP>#{@office_room}>CANCEL>TOO_EARLY: Booking NOT cancelled with start time #{start_time}" } if too_early_to_cancel
                logger.warn { "RBP>#{@office_room}>CANCEL>TOO_LATE: Booking NOT cancelled with start time #{start_time}" } if too_late_to_cancel
            end
        else    # an unsupported reason, just cancel the booking and add support to this driver.
            logger.error { "RBP>#{@office_room}>CANCEL>UNKNOWN_REASON: Cancelled booking with unknown reason, with start time #{start_time}" }
            delete_o365_booking(start_epoch, reason)
        end
    
        self[:last_meeting_started] = ms_epoch
        self[:meeting_pending]      = ms_epoch
        self[:meeting_ending]       = false
        self[:meeting_pending_notice] = false
        true
    end

    def bookings_with_start_time(start_epoch)
        return 0 unless self[:today]
        booking_start_times = self[:today]&.map { |b| Time.parse(b[:Start]).to_i }
        return booking_start_times.count(start_epoch)
    end

    # If last meeting started !== meeting pending then
    #  we'll show a warning on the in room touch panel
    def set_meeting_pending(meeting_ref)
        self[:meeting_ending] = false
        self[:meeting_pending] = meeting_ref
        self[:meeting_pending_notice] = true
    end

    # Meeting ending warning indicator
    # (When meeting_ending !== last_meeting_started then the warning hasn't been cleared)
    # The warning is only displayed when meeting_ending === true
    def set_end_meeting_warning(meeting_ref = nil, extendable = false)
        if self[:last_meeting_started].nil? || self[:meeting_ending] != (meeting_ref || self[:last_meeting_started])
            self[:meeting_ending] = true

            # Allows meeting ending warnings in all rooms
            self[:last_meeting_started] = meeting_ref if meeting_ref
            self[:meeting_canbe_extended] = extendable
        end
    end

    def clear_end_meeting_warning
        self[:meeting_ending] = self[:last_meeting_started]
    end


    
    protected

    # convert an unknown epoch type (s, ms, micros) to s (seconds) epoch
    def epoch(input)
        case input.digits.count
        when 1..12       #(s is typically 10 digits)
            input
        when 13..15       #(ms is typically 13 digits)
            input/1000
        else
            input/1000000
        end
    end

    def delete_or_decline(booking, comment = nil)
        if booking[:email] == @office_room
            logger.warn { "RBP>#{@office_room}>CANCEL>ROOM_OWNED: Deleting booking owned by the room, with start time #{booking[:Start]}" }
            response = @client.delete_booking(booking_id: booking[:id], mailbox: system.email)  # Bookings owned by the room need to be deleted, instead of declined
        else
            logger.warn { "RBP>#{@office_room}>CANCEL>SUCCESS: Declining booking, with start time #{booking[:Start]}" }
            response = @client.decline_meeting(booking_id: booking[:id], mailbox: system.email, comment: comment)
        end
    end

    def delete_o365_booking(delete_start_epoch, reason)
        bookings_deleted = 0
        delete_start_time = Time.at(delete_start_epoch)

        # Find a booking with a matching start time to delete
        self[:today].each_with_index do |booking, i|
            booking_start_epoch = Time.parse(booking[:Start]).to_i 
            next if booking_start_epoch != delete_start_epoch
            if booking[:isAllDay]
                logger.warn { "RBP>#{@office_room}>CANCEL>ALL_DAY: An All Day booking was NOT deleted, with start time #{delete_start_epoch}" }
                next
            end

            case reason
            when RBP_AUTOCANCEL_TRIGGERED
                response = delete_or_decline(booking, self[:booking_timeout_email_message])
            when RBP_STOP_PRESSED
                response = delete_or_decline(booking, self[:booking_cancel_email_message])
            else
                response = delete_or_decline(booking, "The booking was cancelled due to \"#{reason}\"")
            end
            if response.between?(200,204)
                bookings_deleted += 1
                fetch_bookings  # self[:today].delete_at(i) This does not seem to notify the websocket, so call fetch_bookings instead
            end
        end
    end

    def expose_bookings(bookings)
        results = []
        bookings.each{ |booking|
            tz = ActiveSupport::TimeZone.new(booking['start']['timeZone'])      # in tz database format: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
            start_utc   = tz.parse(booking['start']['dateTime']).utc            # output looks like: "2019-05-21 15:50:00 UTC"
            end_utc     = tz.parse(booking['end']['dateTime']).utc                  
            start_time  = start_utc.iso8601                                     # output looks like: "2019-05-21T15:50:00Z+08:00"
            end_time    = end_utc.iso8601

            name =  booking.dig('organizer',:name)  || booking.dig('attendees',0,'name')
            email = booking.dig('organizer',:email) || booking.dig('attendees',0,'email')

            subject = booking['subject']
            if ['private','confidential'].include?(booking['sensitivity'])
                name = "Private"
                subject = "Private"
            end

            results.push({
                :Start => start_time,
                :End => end_time,
                :Subject => subject,
                :id => booking['id'],
                :icaluid => booking['icaluid'],
                :owner => name,
                :email => email,
                :organizer => {:name => name, :email => email},
                :isAllDay => booking['isAllDay']
            })
        }
        results
    end
end
