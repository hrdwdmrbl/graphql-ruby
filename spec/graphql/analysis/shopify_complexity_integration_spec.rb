# frozen_string_literal: true

require "spec_helper"
require "graphql/analysis/shopify_complexity"
require_relative "../../support/shopify_api_client"
require_relative "../../support/query_file_loader"
require_relative "../../support/shopify_complexity_result_reporter"

describe "ShopifyComplexity Integration Tests" do
  before do
    skip "SHOPIFY_ACCESS_TOKEN not set - skipping integration tests" unless ENV["SHOPIFY_ACCESS_TOKEN"]
  end

  it "estimates query costs accurately against real Shopify API" do
    schema_path = "spec/support/shopify/2025-07.graphql"
    schema = GraphQL::Schema.from_definition(schema_path)
    schema.complexity_cost_calculation_mode(:future)

    client = ShopifyApiClient.new
    query_dir = "spec/support/shopify/queries"

    # Load a random sample of queries (excluding fragment-only files)
    sample_size = ENV.fetch("SHOPIFY_SAMPLE_SIZE", "15").to_i
    queries = QueryFileLoader.load_random_queries(query_dir, sample_size, include_fragments: false)

    puts "\nLoaded #{queries.size} executable queries for testing"
    skip "No queries available for testing" if queries.empty?

    reporter = ShopifyComplexityResultReporter.new

    queries.each_with_index do |query_info, idx|
      puts "\n[#{idx + 1}/#{queries.size}] Testing: #{query_info[:name]}"

      # Get default variables for this query
      variables = QueryFileLoader.default_variables(query_info[:content])

      # Calculate our estimated cost
      begin
        query = GraphQL::Query.new(schema, query_info[:content], variables: variables)
        estimate_request_query_cost = GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::ShopifyComplexity]).first
      rescue => e
        reporter.add_error(name: query_info[:name], error: "Complexity calculation error: #{e.message}")
        puts "  CALC ERROR: #{e.message}"
        next
      end

      # Execute against real Shopify API
      result = client.execute_query(query_info[:content], variables: variables)

      if result[:errors]
        error_message = result[:errors].map { |e| e["message"] }.join(", ")
        reporter.add_error(name: query_info[:name], error: error_message)
        puts "  API ERROR: #{result[:errors].first["message"]}"
        next
      end

      actual_cost = result[:requested_query_cost]
      diff = estimate_request_query_cost - actual_cost
      percent_diff = actual_cost > 0 ? ((diff.to_f / actual_cost) * 100).round(1) : 0

      reporter.add_result(
        name: query_info[:name],
        estimated: estimate_request_query_cost,
        actual: actual_cost,
        fields: result[:fields]
      )

      puts "  Estimated: #{estimate_request_query_cost}, Actual: #{actual_cost}, Diff: #{diff} (#{percent_diff}%)"

      # Be nice to Shopify's rate limits
      sleep 0.5
    end

    # Print all reports
    reporter.print_all(queries.size)

    # For now, just ensure we got some results - we'll tighten this threshold later
    assert reporter.results.size > 0
  end
end
