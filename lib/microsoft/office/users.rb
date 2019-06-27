module Microsoft::Officenew::Users
    ##
    # Retrieve a list of users stored in Office365
    # 
    # @param q [String] The query param which filters all users without a name or email matching this string
    # @param limit [String] The maximum number of users to return
    def get_users(q: nil, limit: nil)

        # If we have a query and the query has at least one space
        if q && q.include?(" ")
            # Split it into word tokens
            queries = q.split(" ")
            filter_params = []

            # For each word, create a filtering statement
            queries.each do |q|
                filter_params.push("(startswith(displayName,'#{q}') or startswith(givenName,'#{q}') or startswith(surname,'#{q}') or startswith(mail,'#{q}'))")
            end

            # Join these filtering statements using 'or' and add accountEnabled filter
            filter_param = "(accountEnabled eq true) and #{filter_params.join(" and ")}"
        else
            # Or just add the space-less query to be checked for each field
            filter_param = "(accountEnabled eq true) and (startswith(displayName,'#{q}') or startswith(givenName,'#{q}') or startswith(surname,'#{q}') or startswith(mail,'#{q}'))" if q
        end

        # If we have no query then still only grab enabled accounts
        filter_param = "accountEnabled eq true" if q.nil?

        # Put our params together and make the request
        query_params = {
            '$filter': filter_param,
            '$top': limit
        }.compact
        endpoint = "/v1.0/users"
        request = graph_request(request_method: 'get', endpoints: [endpoint], query: query_params)
        check_response(request)

        # Return the parsed user data
        JSON.parse(request.body)['value'].map {|u| Microsoft::Officenew::User.new(client: self, user: u).user}
    end
end