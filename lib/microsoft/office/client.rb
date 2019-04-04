require 'active_support/time'
require 'oauth2'
require 'microsoft/officenew'
require 'microsoft/office/model'
require 'microsoft/office/user'
require 'microsoft/office/users'
require 'microsoft/office/contact'
require 'microsoft/office/contacts'
require 'microsoft/office/event'
require 'microsoft/office/events'
module Microsoft
    class Error < StandardError
        class ResourceNotFound < Error; end
        class InvalidAuthenticationToken < Error; end
        class BadRequest < Error; end
        class ErrorInvalidIdMalformed < Error; end
        class ErrorAccessDenied < Error; end
    end
end

class Microsoft::Officenew; end

##
# This class provides a client to interface between Microsoft Graph API and ACA Engine. Instances of this class are
# primarily only used for:
#   -
class Microsoft::Officenew::Client
    include Microsoft::Officenew::Events
    include Microsoft::Officenew::Users
    include Microsoft::Officenew::Contacts

    ##
    # Initialize the client for making requests to the Office365 API.
    # @param [String] client_id The client ID of the application registered in the application portal or Azure
    # @param [String] client_secret The client secret of the application registered in the application portal or Azure
    # @param [String] app_site The site in which to send auth requests. This is usually "https://login.microsoftonline.com"
    # @param [String] app_token_url The token URL in which to send token requests
    # @param [String] app_scope The oauth scope to pass to token requests. This is usually "https://graph.microsoft.com/.default"
    # @param [String] graph_domain The domain to pass requests to Graph API. This is usually "https://graph.microsoft.com"
    def initialize(
            client_id:,
            client_secret:,
            app_site:,
            app_token_url:,
            app_scope:,
            graph_domain:,
            save_token: Proc.new{ |token| User.bucket.set("office-token", token) },
            get_token: Proc.new{ User.bucket.get("office-token", quiet: true) }
        )
        @client_id = client_id
        @client_secret = client_secret
        @app_site = app_site
        @app_token_url = app_token_url
        @app_scope = app_scope
        @graph_domain = graph_domain
        @get_token = get_token
        @save_token = save_token
        oauth_options = { site: @app_site,  token_url: @app_token_url }
        oauth_options[:connection_opts] = { proxy: @internet_proxy } if @internet_proxy
        @graph_client ||= OAuth2::Client.new(
            @client_id,
            @client_secret,
            oauth_options
        )
    end


    protected

    ##
    # Passes back either a stored bearer token for Graph API that has yet to expire or
    # grabs a new token and stores it along with the expiry date.
    def graph_token
        # Check if we have a token in couchbase
        # token = User.bucket.get("office-token", quiet: true)
        token = @get_token.call

        # If we don't have a token
        if token.nil? || token[:expiry] <= Time.now.to_i
            # Get a new token with the passed in scope
            new_token = @graph_client.client_credentials.get_token({
                :scope => @app_scope
            })
            # Save both the token and the expiry details
            new_token_model = {
                token: new_token.token,
                expiry: Time.now.to_i + new_token.expires_in,
            }
            @save_token.call(new_token_model)
            # User.bucket.set("office-token", new_token_model)
            return new_token.token
        else
            # Otherwise, use the existing token
            token[:token]
        end
    end

    ##
    # The helper method that abstracts calls to graph API. This method allows for both single requests and 
    # bulk requests using the $batch endpoint.
    def graph_request(request_method:, endpoints:, data:nil, query:{}, headers:{}, bulk: false)
        if bulk
            uv_request_method = :post
            graph_path = "#{@graph_domain}/v1.0/$batch"
            query_string = "?#{query.map { |k,v| "#{k}=#{v}" }.join('&')}"
            data = {
                requests: endpoints.each_with_index.map { |endpoint, i| { id: i, method: request_method.upcase, url: "#{endpoint}#{query_string}" } }
            }
            query = {}
        else
            uv_request_method = request_method.to_sym
            graph_path = "#{@graph_domain}#{endpoints[0]}"
        end

        headers['Authorization'] = "Bearer #{graph_token}"
        headers['Content-Type'] = ENV['GRAPH_CONTENT_TYPE'] || "application/json"
        headers['Prefer'] = ENV['GRAPH_PREFER'] || 'outlook.timezone="Australia/Sydney"'

        log_graph_request(request_method, data, query, headers, graph_path, endpoints)

        graph_api = UV::HttpEndpoint.new(@graph_domain, { inactivity_timeout: 25000, keepalive: false })
        response = graph_api.__send__(uv_request_method, path: graph_path, headers: headers, body: data.to_json, query: query)

        response.value
    end

    def graph_date(date)
        Time.at(date.to_i).utc.iso8601.split("+")[0]
    end

    def log_graph_request(request_method, data, query, headers, graph_path, endpoints=nil)
        STDERR.puts "--------------NEW GRAPH REQUEST------------"
        STDERR.puts "#{request_method} to #{graph_path}"
        STDERR.puts "Data:"
        STDERR.puts data.to_json if data
        STDERR.puts "Query:"
        STDERR.puts query if query
        STDERR.puts "Headers:"
        STDERR.puts headers if headers
        STDERR.puts "Endpoints:"
        STDERR.puts endpoints if endpoints
        STDERR.puts '--------------------------------------------'
        STDERR.flush
    end

    def check_response(response)
        case response.status
        when 200, 201, 204
            return
        when 400
            if response['error']['code'] == 'ErrorInvalidIdMalformed'
                raise Microsoft::Error::ErrorInvalidIdMalformed.new(response.body)
            else
                raise Microsoft::Error::BadRequest.new(response.body)
            end
        when 401
            raise Microsoft::Error::InvalidAuthenticationToken.new(response.body)
        when 403
            raise Microsoft::Error::ErrorAccessDenied.new(response.body)
        when 404
            raise Microsoft::Error::ResourceNotFound.new(response.body)
        end
    end

end