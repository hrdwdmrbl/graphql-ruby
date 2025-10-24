# frozen_string_literal: true

require "spec_helper"
require "graphql/analysis/shopify_complexity"

describe GraphQL::Analysis::ShopifyComplexity do
  let(:schema_path) { "spec/support/shopify/2025-07.graphql" }
  let(:schema) { GraphQL::Schema.from_definition(schema_path) }
  let(:query_string) { File.read("spec/support/shopify/Order.graphql") }

  it "calculates complexity 9 for the sample order query" do
    schema.complexity_cost_calculation_mode(:future)

    query = GraphQL::Query.new(
      schema,
      query_string,
      variables: { "id" => "gid://shopify/Order/12345" }
    )

    complexity = GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::ShopifyComplexity]).first
    assert_equal 9, complexity
  end
end


