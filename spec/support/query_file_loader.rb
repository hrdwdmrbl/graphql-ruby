# frozen_string_literal: true

# Utility to load GraphQL query files for testing
class QueryFileLoader
  # Load a random sample of query files from a directory
  # @param dir [String] Directory path containing .graphql files
  # @param count [Integer] Number of random queries to load
  # @param include_fragments [Boolean] Whether to include fragment-only files
  # @return [Array<Hash>] Array of { path:, content:, name: }
  def self.load_random_queries(dir, count, include_fragments: false)
    query_files = Dir.glob(File.join(dir, "*.graphql"))

    # Filter out fragment-only files unless requested
    unless include_fragments
      query_files = query_files.reject do |file_path|
        content = File.read(file_path)
        fragment_only?(content)
      end
    end

    sampled_files = query_files.sample(count)

    sampled_files.map do |file_path|
      {
        path: file_path,
        name: File.basename(file_path, ".graphql"),
        content: File.read(file_path)
      }
    end
  end

  # Load all query files from a directory
  # @param dir [String] Directory path containing .graphql files
  # @return [Array<Hash>] Array of { path:, content:, name: }
  def self.load_all_queries(dir)
    query_files = Dir.glob(File.join(dir, "*.graphql"))

    query_files.map do |file_path|
      {
        path: file_path,
        name: File.basename(file_path, ".graphql"),
        content: File.read(file_path)
      }
    end
  end

  # Extract variable definitions from a query string
  # @param query_string [String] The GraphQL query
  # @return [Array<String>] Variable names (without $)
  def self.extract_variables(query_string)
    # Match $variableName in query/mutation definitions
    query_string.force_encoding("UTF-8").scan(/\$(\w+):\s*\w+/).flatten.uniq
  end

  # Check if a query requires variables
  # @param query_string [String] The GraphQL query
  # @return [Boolean]
  def self.requires_variables?(query_string)
    extract_variables(query_string).any?
  end

  # Check if a query string is fragment-only (no query/mutation)
  # @param query_string [String] The GraphQL query
  # @return [Boolean]
  def self.fragment_only?(query_string)
    # Check if it starts with fragment and has no query/mutation
    trimmed = query_string.force_encoding("UTF-8").strip
    trimmed.start_with?("fragment") && !trimmed.match?(/\b(query|mutation|subscription)\b/)
  end

  # Get default variables for common query patterns
  # @param query_string [String] The GraphQL query
  # @return [Hash] Default variables to use
  def self.default_variables(query_string)
    vars = {}
    extract_variables(query_string).each do |var_name|
      case var_name
      when "first", "last"
        vars[var_name] = 10
      when "after", "before", "query"
        vars[var_name] = nil  # optional
      when /id/i
        vars[var_name] = "gid://shopify/Product/1" # dummy ID
      else
        vars[var_name] = nil  # skip unknowns
      end
    end
    vars.compact
  end
end
