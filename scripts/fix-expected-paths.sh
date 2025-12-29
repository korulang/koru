#!/bin/bash

echo "🔧 Fixing expected.json file paths after migration..."

# Define the mappings
mappings=(
    "050_PARSER/050_event_multiline_shape:200_COMPILER_FEATURES/210_PARSER/210_001_event_multiline_shape"
    "050_PARSER/051_branch_constructor_multiline:200_COMPILER_FEATURES/210_PARSER/210_002_branch_constructor_multiline"
    "050_PARSER/052_conditional_imports:200_COMPILER_FEATURES/210_PARSER/210_003_conditional_imports"
    "050_PARSER/055_branch_when_clauses:200_COMPILER_FEATURES/210_PARSER/210_004_branch_when_clauses"
    "050_PARSER/055_source_parameter_syntax:200_COMPILER_FEATURES/210_PARSER/210_005_source_parameter_syntax"
    "050_PARSER/055b_flow_checker_validation:200_COMPILER_FEATURES/210_PARSER/210_006_flow_checker_validation"
    "050_PARSER/055c_flow_checker_missing_else:200_COMPILER_FEATURES/210_PARSER/210_007_flow_checker_missing_else"
    "050_PARSER/058_tap_nested_continuation:200_COMPILER_FEATURES/210_PARSER/210_008_tap_nested_continuation"
    "050_PARSER/059_source_with_scope_capture:200_COMPILER_FEATURES/210_PARSER/210_009_source_with_scope_capture"
    "050_PARSER/060_module_annotations:200_COMPILER_FEATURES/210_PARSER/210_010_module_annotations"
    "050_PARSER/060_optional_branch_catchall:200_COMPILER_FEATURES/210_PARSER/210_011_optional_branch_catchall"
    "050_PARSER/060b_missing_required_branch:200_COMPILER_FEATURES/210_PARSER/210_012_missing_required_branch"
    "050_PARSER/061_void_event_chaining:200_COMPILER_FEATURES/210_PARSER/210_013_void_event_chaining"
    "050_PARSER/062_void_chaining_nested:200_COMPILER_FEATURES/210_PARSER/210_014_void_chaining_nested"
    "050_PARSER/064_abstract_impl:200_COMPILER_FEATURES/210_PARSER/210_015_abstract_impl"
    "050_PARSER/065_optional_branches_ignored:200_COMPILER_FEATURES/210_PARSER/210_016_optional_branches_ignored"
    "050_PARSER/066_catchall_end_to_end:200_COMPILER_FEATURES/210_PARSER/210_017_catchall_end_to_end"
    "050_PARSER/067_multiline_annotations:200_COMPILER_FEATURES/210_PARSER/210_018_multiline_annotations"
    "050_PARSER/100_subflow_multiline_call:200_COMPILER_FEATURES/210_PARSER/210_019_subflow_multiline_call"
    "050_PARSER/101_transitive_imports:200_COMPILER_FEATURES/210_PARSER/210_020_transitive_imports"
    "050_PARSER/102_source_phantom_syntax:200_COMPILER_FEATURES/210_PARSER/210_021_source_phantom_syntax"
    "050_PARSER/103_invocation_parentheses_rules:200_COMPILER_FEATURES/210_PARSER/210_022_invocation_parentheses_rules"
    "050_PARSER/104_template_interpolation:200_COMPILER_FEATURES/210_PARSER/210_023_template_interpolation"
    "050_PARSER/105_source_scope_capture:200_COMPILER_FEATURES/210_PARSER/210_024_source_scope_capture"
    "050_PARSER/106_source_item_transform:200_COMPILER_FEATURES/210_PARSER/210_025_source_item_transform"
    "050_PARSER/107_comptime_depends_on:200_COMPILER_FEATURES/210_PARSER/210_026_comptime_depends_on"
    "050_PARSER/108_program_ast_transform:200_COMPILER_FEATURES/210_PARSER/210_027_program_ast_transform"
    "050_PARSER/109_render_html_working:200_COMPILER_FEATURES/210_PARSER/210_028_render_html_working"
    "050_PARSER/110_transform_requires_comptime:200_COMPILER_FEATURES/210_PARSER/210_029_transform_requires_comptime"
    "050_PARSER/111_comptime_flows:200_COMPILER_FEATURES/210_PARSER/210_030_comptime_flows"
    "600_COMPTIME/602b_annotations_in_ast:200_COMPILER_FEATURES/210_PARSER/210_031_annotations_in_ast"
    "600_COMPTIME/618_implicit_source_param:200_COMPILER_FEATURES/210_PARSER/210_032_implicit_source_param"
    "600_COMPTIME/631_ast_dump_taps:200_COMPILER_FEATURES/210_PARSER/210_033_ast_dump_taps"
    "600_COMPTIME/650_parser_wrapper:200_COMPILER_FEATURES/210_PARSER/210_034_parser_wrapper"
    "000_CORE_LANGUAGE/101_hello_world:000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_001_hello_world"
    "000_CORE_LANGUAGE/102_simple_event:000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_002_simple_event"
    "000_CORE_LANGUAGE/103_simple_flow:000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_001_simple_flow"
    "000_CORE_LANGUAGE/104_multiple_flows:000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_002_multiple_flows"
    "000_CORE_LANGUAGE/105_inline_flow_basic:000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_003_inline_flow_basic"
    "000_CORE_LANGUAGE/105_void_event:000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_004_void_event"
    "000_CORE_LANGUAGE/105b_void_event_chained:000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_005_void_event_chained"
    "000_CORE_LANGUAGE/106_inline_flow_chained:000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_006_inline_flow_chained"
    "000_CORE_LANGUAGE/107_inline_flow_binding:000_CORE_LANGUAGE/040_CONTROL_FLOW/040_001_inline_flow_binding"
    "000_CORE_LANGUAGE/108_inline_flow_branches:000_CORE_LANGUAGE/040_CONTROL_FLOW/040_002_inline_flow_branches"
    "000_CORE_LANGUAGE/109_event_multiline_shape:000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_003_event_multiline_shape"
)

# Fix expected.json files
for mapping in "${mappings[@]}"; do
    old_path="${mapping%:*}"
    new_path="${mapping#*:}"
    echo "  🔄 $old_path → $new_path"
    
    # Find and replace in all expected.json files
    find tests/regression -name "expected.json" -exec sed -i '' "s|tests/regression/$old_path|tests/regression/$new_path|g" {} \;
done

echo "✅ Expected.json files updated!"
echo ""
echo "📋 Next steps:"
echo "1. Run tests to see improvement: ./run_regression.sh 210"
echo "2. Fix any remaining import path issues in .kz files"
echo "3. Update any hardcoded references in documentation"
