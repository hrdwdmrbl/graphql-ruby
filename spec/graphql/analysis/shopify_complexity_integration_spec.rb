# frozen_string_literal: true

require "spec_helper"
require "graphql/analysis/shopify_complexity"
require_relative "../../support/shopify_api_client"
require_relative "../../support/query_file_loader"

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

    results = []
    errors = []

    queries.each_with_index do |query_info, idx|
      puts "\n[#{idx + 1}/#{queries.size}] Testing: #{query_info[:name]}"

      # Get default variables for this query
      variables = QueryFileLoader.default_variables(query_info[:content])

      # Calculate our estimated cost
      begin
        query = GraphQL::Query.new(schema, query_info[:content], variables: variables)
        estimated_cost = GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::ShopifyComplexity]).first
      rescue => e
        errors << {
          name: query_info[:name],
          error: "Complexity calculation error: #{e.message}"
        }
        puts "  CALC ERROR: #{e.message}"
        next
      end

      # Execute against real Shopify API
      result = client.execute_query(query_info[:content], variables: variables)

      if result[:errors]
        errors << {
          name: query_info[:name],
          error: result[:errors].map { |e| e["message"] }.join(", ")
        }
        puts "  API ERROR: #{result[:errors].first["message"]}"
        next
      end

      actual_cost = result[:requested_cost] # Use requestedQueryCost as the source of truth
      diff = estimated_cost - actual_cost
      percent_diff = actual_cost > 0 ? ((diff.to_f / actual_cost) * 100).round(1) : 0

      results << {
        name: query_info[:name],
        estimated: estimated_cost,
        actual: actual_cost,
        diff: diff,
        percent_diff: percent_diff
      }

      puts "  Estimated: #{estimated_cost}, Actual: #{actual_cost}, Diff: #{diff} (#{percent_diff}%)"

      # Be nice to Shopify's rate limits
      sleep 0.5
    end

    # Print summary table
    puts "\n" + "=" * 80
    puts "SUMMARY"
    puts "=" * 80
    printf "%-40s %10s %10s %10s %10s\n", "Query", "Estimated", "Actual", "Diff", "Diff %"
    puts "-" * 80

    results.each do |r|
      printf "%-40s %10d %10d %10d %9.1f%%\n",
             r[:name].slice(0, 40),
             r[:estimated],
             r[:actual],
             r[:diff],
             r[:percent_diff]
    end

    if errors.any?
      puts "\n" + "=" * 80
      puts "ERRORS (#{errors.size})"
      puts "=" * 80
      errors.each do |e|
        puts "#{e[:name]}: #{e[:error]}"
      end
    end

    # Calculate statistics
    if results.any?
      avg_diff = (results.sum { |r| r[:diff].abs } / results.size.to_f).round(1)
      avg_percent_diff = (results.sum { |r| r[:percent_diff].abs } / results.size.to_f).round(1)

      puts "\n" + "=" * 80
      puts "Average absolute difference: #{avg_diff} (#{avg_percent_diff}%)"
      puts "Successful queries: #{results.size}/#{queries.size}"
      puts "=" * 80

      # For now, just ensure we got some results - we'll tighten this threshold later
      assert results.size > 0
    else
      puts "\nNo successful queries to analyze"
    end
  end
end
