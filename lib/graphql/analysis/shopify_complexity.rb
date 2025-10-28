# frozen_string_literal: true

require "graphql/analysis"

module GraphQL
  module Analysis
    # A shopify complexity calculator that applies specific rules for different field types.
    class ShopifyComplexity < GraphQL::Analysis::QueryComplexity
      # This class overrides the default complexity calculation for a field.
      # Ref: https://shopify.dev/docs/api/usage/limits#cost-calculation
      # Ref: https://graphql-ruby.org/queries/complexity_and_depth.html#how-complexity-scoring-works
      # Shopify says: For simplicity, that ^ summary describes all linear tally strategies.
      #   We do incorporate logarithmic scaling into connection fields to cost them more favorably for a client.
      class ShopifyScopedTypeComplexity < ScopedTypeComplexity
        def own_complexity(child_complexity)
          field_defn = @field_definition
          return child_complexity || 0 unless field_defn

          query = @query
          nodes = @nodes

          if field_defn.owner == query.schema.mutation
            # Shopify: mutations have a flat cost of 10, regardless of return fields
            10
          elsif field_defn.connection?
            # Shopify-style: only multiply the items (nodes/edges) subtree by an effective, capped page size
            # and add a small, separate metadata cost (eg, pageInfo subfields), avoiding nested double-multiplication.
            lookahead = GraphQL::Execution::Lookahead.new(query: query, field: field_defn, ast_nodes: nodes, owner_type: @parent_type)

            has_page_info = false
            lookahead.selections.each do |sel|
              name = sel.name.to_s
              if name == "pageInfo"
                has_page_info = true
              end
            end

            # Calculate items complexity (subtract pageInfo if present)
            base_children = (child_complexity || 0)
            items_complexity = has_page_info ? (base_children - 1) : base_children
            items_complexity = 0 if items_complexity < 0

            # Shopify formula: cost = mult × (items_complexity + 1) + 2
            # The +1 accounts for the base cost of accessing items
            # The +2 is the metadata cost (always present, even without pageInfo selection)
            mult = effective_connection_size(nodes, query, field_defn)
            (mult * (items_complexity + 1)) + 2
          else
            field_type = field_defn.type.unwrap
            case field_type.kind
            when GraphQL::TypeKinds::SCALAR, GraphQL::TypeKinds::ENUM
              0
            when GraphQL::TypeKinds::OBJECT
              1 + (child_complexity || 0)
            when GraphQL::TypeKinds::INTERFACE, GraphQL::TypeKinds::UNION
              # Shopify: The field itself costs 1, plus the maximum of possible type selections
              # But since all scalars cost 0, we effectively get max(child_complexity, 1)
              # to ensure the field itself has a base cost
              [child_complexity || 0, 1].max
            else
              child_complexity || 0
            end
          end
        end

        private

        # Effective connection size using Shopify's bucketing system
        # Based on observed behavior from actual Shopify API
        # Returns the multiplier for the connection based on the requested page size
        def effective_connection_size(nodes, query, field_defn)
          raw = 1
          nodes.each do |node|
            args = query.arguments_for(node, field_defn)
            current = args[:first] || args[:last]
            if current
              raw = [raw, current].max
            end
          end

          # Shopify uses a bucketed logarithmic scale for multipliers
          # Empirically observed buckets:
          return 1 if raw <= 2
          return 2 if raw <= 4
          return 3 if raw <= 7
          return 4 if raw <= 12
          return 5 if raw <= 20
          return 6 if raw <= 39
          return 7 if raw <= 59
          return 8 if raw <= 79
          return 9 if raw <= 99
          return 10 if raw <= 149
          return 11 if raw <= 249

          # For larger values, approximate with logarithmic growth
          3 + Math.log2(raw).floor
        end
      end

      # Override on_enter_field from QueryComplexity to use our shopify scope class.
      # This is a bit of a reimplementation of the base method, but it's necessary
      # to inject our shopify complexity calculation logic.
      def on_enter_field(node, parent, visitor)
        # We don't want to visit fragment definitions,
        # we'll visit them when we hit the spreads instead
        return if visitor.visiting_fragment_definition?
        return if visitor.skipping?
        return if @skip_introspection_fields && visitor.field_definition.introspection?
        parent_type = visitor.parent_type_definition
        field_key = node.alias || node.name

        # Find or create a complexity scope stack for this query.
        scopes_stack = @complexities_on_type_by_query[visitor.query] ||= [ShopifyScopedTypeComplexity.new(nil, nil, query, visitor.response_path)]

        # Find or create the complexity costing node for this field.
        scope = scopes_stack.last[parent_type][field_key] ||= ShopifyScopedTypeComplexity.new(parent_type, visitor.field_definition, visitor.query, visitor.response_path)
        scope.nodes.push(node)
        scopes_stack.push(scope)
      end
    end
  end
end
