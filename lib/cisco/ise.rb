require 'uv-rays'
require 'nokogiri'

# Documentation:
# https://www.cisco.com/c/en/us/td/docs/security/ise/1-4/api_ref_guide/api_ref_book/ise_api_ref_ch1.html

module Cisco; end
class Cisco::ISE
    def initialize(host, user, pass, floor_mappings)
        @host = UV::HttpEndpoint.new(host)
        @ldap = Array(use_ou)
        @headers = {
            authorization: [user, pass]
        }
    end

    def locate(user: nil)
        resp = @host.get(path: "/admin/API/mnt/Session/UserName/#{user}", headers: @headers).value

        return nil if resp.status == 404
        raise "request failed #{resp.status}\n#{resp.body}" unless (200...300).include?(resp.status)

        session = Nokogiri::XML(resp.body)
    end
end
