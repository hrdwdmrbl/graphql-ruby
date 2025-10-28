# frozen_string_literal: true

require "spec_helper"
require "graphql/analysis/shopify_complexity"
require_relative "shopify_api_client"
require_relative "query_file_loader"
require_relative "shopify_complexity_result_reporter"

# Utility class to run a single GraphQL query and compare our calculated cost
# with Shopify's real cost estimate. This is useful for debugging specific queries.
class ShopifyQueryCostRunner
  def initialize(schema_path = "spec/support/shopify/2025-07.graphql")
    @schema = GraphQL::Schema.from_definition(schema_path)
    @schema.complexity_cost_calculation_mode(:future)
    @client = ShopifyApiClient.new
    @reporter = ShopifyComplexityResultReporter.new
  end

  # Run a query from a file and compare costs
  def run_query_file(file_path, variables: {})
    query_content = File.read(file_path)
    query_name = File.basename(file_path, ".graphql")
    run_query_string(query_content, query_name: query_name, variables: variables)
  end

  # Run a query string and compare costs
  def run_query_string(query_string, query_name: "query", variables: {})
    puts "\nRunning query: #{query_name}"
    puts "=" * 80

    # Calculate our estimated cost
    begin
      query = GraphQL::Query.new(@schema, query_string, variables: variables)
      estimated_cost = GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::ShopifyComplexity]).first
      puts "✓ Calculated estimated cost: #{estimated_cost}"
    rescue => e
      @reporter.add_error(name: query_name, error: "Complexity calculation error: #{e.message}")
      puts "✗ CALC ERROR: #{e.message}"
      return false
    end

    # Execute against real Shopify API
    result = @client.execute_query(query_string, variables: variables)

    if result[:errors]
      error_message = result[:errors].map { |e| e["message"] }.join(", ")
      @reporter.add_error(name: query_name, error: error_message)
      puts "✗ API ERROR: #{error_message}"
      return false
    end

    # Compare costs
    actual_cost = result[:requested_query_cost]
    diff = estimated_cost - actual_cost
    percent_diff = actual_cost > 0 ? ((diff.to_f / actual_cost) * 100).round(1) : 0

    @reporter.add_result(
      name: query_name,
      estimated: estimated_cost,
      actual: actual_cost,
      fields: result[:fields]
    )

    # Print results
    puts "✓ Actual cost from Shopify: #{actual_cost}"
    puts
    puts "Comparison:"
    puts "  Estimated: #{estimated_cost}"
    puts "  Actual:    #{actual_cost}"
    puts "  Diff:      #{diff} (#{percent_diff}%)"

    # Print field costs if available
    if result[:fields] && result[:fields].any?
      puts
      puts "Field costs:"
      print_field_costs(result[:fields])
    end

    puts "=" * 80

    true
  end

  # Print detailed field cost information
  def print_field_costs(fields, indent = 2)
    spaces = " " * indent
    fields.each do |field|
      next unless field.is_a?(Hash)
      request_cost = field[:request_cost]
      child_complexity = field[:child_complexity]
      puts "#{spaces}#{field[:name]}: request_cost=#{request_cost}, child_complexity=#{child_complexity}"
      if field[:fields]&.any?
        print_field_costs(field[:fields], indent + 2)
      end
    end
  end

  # Get the reporter (for programmatic access to results)
  attr_reader :reporter
end

# CLI Interface for standalone usage
if __FILE__ == $0
  # Example usage from command line:
  # ruby spec/support/shopify_query_cost_runner.rb spec/support/shopify/Order.graphql

  require "json"

  if ARGV.empty?
    puts "Usage: ruby spec/support/shopify_query_cost_runner.rb <query_file> [variables_json]"
    puts
    puts "Examples:"
    puts "  ruby spec/support/shopify_query_cost_runner.rb spec/support/shopify/Order.graphql"
    puts "  ruby spec/support/shopify_query_cost_runner.rb spec/support/shopify/Orders.graphql '{\"first\": 250}'"
    exit 1
  end

  query_file = ARGV[0]
  variables = ARGV[1] ? JSON.parse(ARGV[1]) : {}

  unless File.exist?(query_file)
    puts "Error: File not found: #{query_file}"
    exit 1
  end

  unless ENV["SHOPIFY_ACCESS_TOKEN"]
    puts "Error: SHOPIFY_ACCESS_TOKEN environment variable not set"
    exit 1
  end

  runner = ShopifyQueryCostRunner.new
  success = runner.run_query_file(query_file, variables: variables)
  exit(success ? 0 : 1)
end
