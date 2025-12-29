#!/bin/bash
# Koru Test Suite Reorganization Script
# Migrates from current broken structure to new hierarchical system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "════════════════════════════════════════"
echo "    KORU TEST SUITE REORGANIZATION"
echo "════════════════════════════════════════"
echo ""

# Backup current structure
echo "${BLUE}📦 Creating backup...${NC}"
BACKUP_DIR="tests/regression_backup_$(date +%Y%m%d_%H%M%S)"
if [ -d "$BACKUP_DIR" ]; then
    echo "${YELLOW}⚠️  Backup already exists, skipping...${NC}"
else
    cp -r tests/regression "$BACKUP_DIR"
    echo "${GREEN}✅ Backup created: $BACKUP_DIR${NC}"
fi

echo ""
echo "${BLUE}🔧 Creating new directory structure...${NC}"

# Create new category structure
mkdir -p tests/regression/{000_CORE_LANGUAGE,100_MODULE_SYSTEM,200_COMPILER_FEATURES,300_ADVANCED_FEATURES,400_RUNTIME_FEATURES,500_INTEGRATION_TESTING,900_EXAMPLES_SHOWCASE}

# Create subcategories
mkdir -p tests/regression/000_CORE_LANGUAGE/{010_BASIC_SYNTAX,020_EVENTS_FLOWS,030_TYPES_VALUES,040_CONTROL_FLOW}
mkdir -p tests/regression/100_MODULE_SYSTEM/{110_IMPORTS,120_NAMESPACES,130_PACKAGES}
mkdir -p tests/regression/200_COMPILER_FEATURES/{210_PARSER,220_COMPILATION,230_CODEGEN,240_OPTIMIZATION}
mkdir -p tests/regression/300_ADVANCED_FEATURES/{310_COMPTIME,320_MACROS_METAPROGRAMMING,330_PHANTOM_TYPES,340_FUSION}
mkdir -p tests/regression/400_RUNTIME_FEATURES/{410_PURITY_CHECKING,420_PERFORMANCE,430_COORDINATION}
mkdir -p tests/regression/500_INTEGRATION_TESTING/{510_NEGATIVE_TESTS,520_BUG_REPRODUCTION,530_REGRESSION}
mkdir -p tests/regression/900_EXAMPLES_SHOWCASE/{910_LANGUAGE_SHOOTOUT,920_DEMO_APPLICATIONS}

echo "${GREEN}✅ New structure created${NC}"

echo ""
echo "${BLUE}📋 Creating migration mapping...${NC}"
cat > MIGRATION_MAPPING.md << 'EOF'
# Test Suite Migration Mapping

## Core Language (000)
- `000_CORE_LANGUAGE/101_hello_world` → `000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_001_hello_world`
- `000_CORE_LANGUAGE/102_simple_event` → `000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_002_simple_event`
- `000_CORE_LANGUAGE/103_simple_flow` → `000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_001_simple_flow`
- `000_CORE_LANGUAGE/104_multiple_flows` → `000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_002_multiple_flows`
- `000_CORE_LANGUAGE/105_inline_flow_basic` → `000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_003_inline_flow_basic`
- `000_CORE_LANGUAGE/105_void_event` → `000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_004_void_event`
- `000_CORE_LANGUAGE/105b_void_event_chained` → `000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_005_void_event_chained`
- `000_CORE_LANGUAGE/106_inline_flow_chained` → `000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_006_inline_flow_chained`
- `000_CORE_LANGUAGE/107_inline_flow_binding` → `000_CORE_LANGUAGE/040_CONTROL_FLOW/040_001_inline_flow_binding`
- `000_CORE_LANGUAGE/108_inline_flow_branches` → `000_CORE_LANGUAGE/040_CONTROL_FLOW/040_002_inline_flow_branches`
- `000_CORE_LANGUAGE/109_event_multiline_shape` → `000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_003_event_multiline_shape`

## Parser (050 → 210)
- `050_PARSER/050_event_multiline_shape` → `200_COMPILER_FEATURES/210_PARSER/210_001_event_multiline_shape`
- `050_PARSER/051_branch_constructor_multiline` → `200_COMPILER_FEATURES/210_PARSER/210_002_branch_constructor_multiline`
- `050_PARSER/052_conditional_imports` → `200_COMPILER_FEATURES/210_PARSER/210_003_conditional_imports`
- `050_PARSER/053_cross_module_type_basic` → `200_COMPILER_FEATURES/220_COMPILATION/220_001_cross_module_type_basic`
- `050_PARSER/055_branch_when_clauses` → `200_COMPILER_FEATURES/210_PARSER/210_004_branch_when_clauses`
- `050_PARSER/055_source_parameter_syntax` → `200_COMPILER_FEATURES/210_PARSER/210_005_source_parameter_syntax`
- `050_PARSER/058_tap_nested_continuation` → `200_COMPILER_FEATURES/210_PARSER/210_006_tap_nested_continuation`
- `050_PARSER/059_source_with_scope_capture` → `200_COMPILER_FEATURES/210_PARSER/210_007_source_with_scope_capture`
- `050_PARSER/060_module_annotations` → `200_COMPILER_FEATURES/210_PARSER/210_008_module_annotations`
- `050_PARSER/061_void_event_chaining` → `200_COMPILER_FEATURES/210_PARSER/210_009_void_event_chaining`
- `050_PARSER/064_abstract_impl` → `200_COMPILER_FEATURES/210_PARSER/210_010_abstract_impl`
- `050_PARSER/065_optional_branches_ignored` → `200_COMPILER_FEATURES/210_PARSER/210_011_optional_branches_ignored`
- `050_PARSER/066_catchall_end_to_end` → `200_COMPILER_FEATURES/210_PARSER/210_012_catchall_end_to_end`
- `050_PARSER/067_multiline_annotations` → `200_COMPILER_FEATURES/210_PARSER/210_013_multiline_annotations`
- `050_PARSER/090_unclosed_input_brace` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_001_unclosed_input_brace`
- `050_PARSER/091_unclosed_branch_brace` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_002_unclosed_branch_brace`
- `050_PARSER/092_unclosed_string` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_003_unclosed_string`
- `050_PARSER/093_invalid_pipe_operator` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_004_invalid_pipe_operator`
- `050_PARSER/094_missing_event_name` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_005_missing_event_name`
- `050_PARSER/095_missing_field_colon` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_006_missing_field_colon`
- `050_PARSER/096_unclosed_flow_parens` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_007_unclosed_flow_parens`
- `050_PARSER/097_invalid_continuation` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_008_invalid_continuation`
- `050_PARSER/098_unexpected_token` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_009_unexpected_token`
- `050_PARSER/099_unclosed_annotation` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_010_unclosed_annotation`

## Imports (100 → 110)
- `100_IMPORTS/150_file_import_basic` → `100_MODULE_SYSTEM/110_IMPORTS/110_001_file_import_basic`
- `100_IMPORTS/151_directory_import_basic` → `100_MODULE_SYSTEM/110_IMPORTS/110_002_directory_import_basic`
- `100_IMPORTS/152_directory_import_public` → `100_MODULE_SYSTEM/110_IMPORTS/110_003_directory_import_public`
- `100_IMPORTS/153_file_processor` → `100_MODULE_SYSTEM/110_IMPORTS/110_004_file_processor`
- `100_IMPORTS/154_deep_error_handling` → `100_MODULE_SYSTEM/110_IMPORTS/110_005_deep_error_handling`
- `100_IMPORTS/155_transitive_file_import` → `100_MODULE_SYSTEM/110_IMPORTS/110_006_transitive_file_import`
- `100_IMPORTS/156_dir_import_basic` → `100_MODULE_SYSTEM/110_IMPORTS/110_007_dir_import_basic`
- `100_IMPORTS/156b_dir_import_no_pub` → `100_MODULE_SYSTEM/110_IMPORTS/110_008_dir_import_no_pub`
- `100_IMPORTS/157_directory_namespace_collision` → `100_MODULE_SYSTEM/120_NAMESPACES/120_001_directory_namespace_collision`
- `100_IMPORTS/159_dir_import_dotted` → `100_MODULE_SYSTEM/110_IMPORTS/110_009_dir_import_dotted`
- `100_IMPORTS/160_dir_import_flow` → `100_MODULE_SYSTEM/110_IMPORTS/110_010_dir_import_flow`
- `100_IMPORTS/161_ast_json_with_stdlib` → `200_COMPILER_FEATURES/220_COMPILATION/220_002_ast_json_with_stdlib`
- `100_IMPORTS/162_cross_module_type_basic` → `200_COMPILER_FEATURES/220_COMPILATION/220_003_cross_module_type_basic`
- `100_IMPORTS/164_cross_module_type_nested` → `200_COMPILER_FEATURES/220_COMPILATION/220_004_cross_module_type_nested`
- `100_IMPORTS/165_parent_plus_submodule` → `100_MODULE_SYSTEM/110_IMPORTS/110_011_parent_plus_submodule`
- `100_IMPORTS/166_full_package_import` → `100_MODULE_SYSTEM/130_PACKAGES/130_001_full_package_import`
- `100_IMPORTS/167_optional_parent` → `100_MODULE_SYSTEM/110_IMPORTS/110_012_optional_parent`
- `100_IMPORTS/168_import_registers_taps` → `300_ADVANCED_FEATURES/310_COMPTIME/310_001_import_registers_taps`
- `100_IMPORTS/168b_import_registers_taps_wildcards` → `300_ADVANCED_FEATURES/310_COMPTIME/310_002_import_registers_taps_wildcards`
- `100_IMPORTS/169_local_name_priority` → `100_MODULE_SYSTEM/120_NAMESPACES/120_002_local_name_priority`
- `100_IMPORTS/170_module_event_globbing` → `100_MODULE_SYSTEM/110_IMPORTS/110_013_module_event_globbing`
- `100_IMPORTS/180_concrete_source_concrete_branch` → `300_ADVANCED_FEATURES/340_FUSION/340_001_concrete_source_concrete_branch`
- `100_IMPORTS/181_concrete_source_metatype` → `300_ADVANCED_FEATURES/340_FUSION/340_002_concrete_source_metatype`
- `100_IMPORTS/182_universal_wildcard_metatype` → `300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_001_universal_wildcard_metatype`
- `100_IMPORTS/183_module_wildcard_metatype` → `300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_002_module_wildcard_metatype`

## Comptime (600 → 310)
- `600_COMPTIME/601_shorthand_syntax` → `300_ADVANCED_FEATURES/310_COMPTIME/310_003_shorthand_syntax`
- `600_COMPTIME/602_annotation_syntax` → `300_ADVANCED_FEATURES/310_COMPTIME/310_004_annotation_syntax`
- `600_COMPTIME/602b_annotations_in_ast` → `200_COMPILER_FEATURES/210_PARSER/210_014_annotations_in_ast`
- `600_COMPTIME/603_annotation_inline_syntax` → `300_ADVANCED_FEATURES/310_COMPTIME/310_005_annotation_inline_syntax`
- `600_COMPTIME/603_event_taps` → `300_ADVANCED_FEATURES/310_COMPTIME/310_006_event_taps`
- `600_COMPTIME/603b_event_taps_nested` → `300_ADVANCED_FEATURES/310_COMPTIME/310_007_event_taps_nested`
- `600_COMPTIME/604_annotation_vertical_syntax` → `300_ADVANCED_FEATURES/310_COMPTIME/310_008_annotation_vertical_syntax`
- `600_COMPTIME/604_multiple_taps` → `300_ADVANCED_FEATURES/310_COMPTIME/310_009_multiple_taps`
- `600_COMPTIME/605_annotation_edge_cases` → `300_ADVANCED_FEATURES/310_COMPTIME/310_010_annotation_edge_cases`
- `600_COMPTIME/605_wildcard_patterns` → `300_ADVANCED_FEATURES/310_COMPTIME/310_011_wildcard_patterns`
- `600_COMPTIME/606_module_taps` → `300_ADVANCED_FEATURES/310_COMPTIME/310_012_module_taps`
- `600_COMPTIME/607_tap_chains` → `300_ADVANCED_FEATURES/310_COMPTIME/310_013_tap_chains`
- `600_COMPTIME/608_taps_with_labels` → `300_ADVANCED_FEATURES/310_COMPTIME/310_014_taps_with_labels`
- `600_COMPTIME/608_transition_metatype` → `300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_003_transition_metatype`
- `600_COMPTIME/608b_profile_metatype` → `400_RUNTIME_FEATURES/420_PERFORMANCE/420_001_profile_metatype`
- `600_COMPTIME/608c_profile_release` → `400_RUNTIME_FEATURES/420_PERFORMANCE/420_002_profile_release`
- `600_COMPTIME/609_when_clauses` → `300_ADVANCED_FEATURES/310_COMPTIME/310_015_when_clauses`
- `600_COMPTIME/610_annotations` → `300_ADVANCED_FEATURES/310_COMPTIME/310_016_annotations`
- `600_COMPTIME/611_namespace_wildcards` → `300_ADVANCED_FEATURES/310_COMPTIME/310_017_namespace_wildcards`
- `600_COMPTIME/612_ccp_opt_in` → `300_ADVANCED_FEATURES/310_COMPTIME/310_018_ccp_opt_in`
- `600_COMPTIME/613_ccp_flag_injection` → `300_ADVANCED_FEATURES/310_COMPTIME/310_019_ccp_flag_injection`
- `600_COMPTIME/614_ccp_flag_only` → `300_ADVANCED_FEATURES/310_COMPTIME/310_020_ccp_flag_only`
- `600_COMPTIME/615_user_coordinator` → `400_RUNTIME_FEATURES/430_COORDINATION/430_001_user_coordinator`
- `600_COMPTIME/616_backend_annotation` → `200_COMPILER_FEATURES/230_CODEGEN/230_001_backend_annotation`
- `600_COMPTIME/618_implicit_source_param` → `200_COMPILER_FEATURES/210_PARSER/210_015_implicit_source_param`
- `600_COMPTIME/618b_invalid_module_qualifier` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_011_invalid_module_qualifier`
- `600_COMPTIME/619_build_requires_basic` → `300_ADVANCED_FEATURES/310_COMPTIME/310_021_build_requires_basic`
- `600_COMPTIME/620_multiline_params` → `300_ADVANCED_FEATURES/310_COMPTIME/310_022_multiline_params`
- `600_COMPTIME/621_scoped_patterns` → `300_ADVANCED_FEATURES/310_COMPTIME/310_023_scoped_patterns`
- `600_COMPTIME/621_shorthand_field_params` → `300_ADVANCED_FEATURES/310_COMPTIME/310_024_shorthand_field_params`
- `600_COMPTIME/622_qualified_patterns` → `300_ADVANCED_FEATURES/310_COMPTIME/310_025_qualified_patterns`
- `600_COMPTIME/624_destination_scoping` → `300_ADVANCED_FEATURES/310_COMPTIME/310_026_destination_scoping`
- `600_COMPTIME/625_conditional_imports` → `300_ADVANCED_FEATURES/310_COMPTIME/310_027_conditional_imports`
- `600_COMPTIME/626_meta_events` → `300_ADVANCED_FEATURES/320_MACROS_METAPROGRAMMING/320_001_meta_events`
- `600_COMPTIME/627_conditional_import_flag_off` → `300_ADVANCED_FEATURES/310_COMPTIME/310_028_conditional_import_flag_off`
- `600_COMPTIME/628_conditional_import_flag_on` → `300_ADVANCED_FEATURES/310_COMPTIME/310_029_conditional_import_flag_on`
- `600_COMPTIME/629_profiler_loop` → `400_RUNTIME_FEATURES/420_PERFORMANCE/420_003_profiler_loop`
- `600_COMPTIME/630_compiler_context` → `200_COMPILER_FEATURES/220_COMPILATION/220_005_compiler_context`
- `600_COMPTIME/631_ast_dump_taps` → `200_COMPILER_FEATURES/210_PARSER/210_016_ast_dump_taps`
- `600_COMPTIME/632_package_requires_npm` → `100_MODULE_SYSTEM/130_PACKAGES/130_002_package_requires_npm`
- `600_COMPTIME/640_build_command_sh` → `300_ADVANCED_FEATURES/310_COMPTIME/310_030_build_command_sh`
- `600_COMPTIME/641_flow_annotations` → `300_ADVANCED_FEATURES/310_COMPTIME/310_031_flow_annotations`
- `600_COMPTIME/642_default_override_basic` → `300_ADVANCED_FEATURES/310_COMPTIME/310_032_default_override_basic`
- `600_COMPTIME/643_multiple_defaults_error` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_012_multiple_defaults_error`
- `600_COMPTIME/644_ambiguous_override_error` → `500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_013_ambiguous_override_error`
- `600_COMPTIME/645_default_with_dependencies` → `300_ADVANCED_FEATURES/310_COMPTIME/310_033_default_with_dependencies`
- `600_COMPTIME/650_parser_wrapper` → `200_COMPILER_FEATURES/210_PARSER/210_017_parser_wrapper`
- `600_COMPTIME/651_emitter_wrapper` → `200_COMPILER_FEATURES/230_CODEGEN/230_002_emitter_wrapper`
- `600_COMPTIME/652_tap_comptime_annotation` → `300_ADVANCED_FEATURES/310_COMPTIME/310_034_tap_comptime_annotation`

## Performance (2000 → 420)
- `2000_PERFORMANCE/2011_multicast_scaling` → `400_RUNTIME_FEATURES/420_PERFORMANCE/420_004_multicast_scaling`
- `2000_PERFORMANCE/2012_conditional_taps` → `400_RUNTIME_FEATURES/420_PERFORMANCE/420_005_conditional_taps`
- `2000_PERFORMANCE/2004_rings_vs_channels` → `400_RUNTIME_FEATURES/420_PERFORMANCE/420_006_rings_vs_channels`

## Purity (1000 → 410)
- `1000_PURITY/1001_pure_annotation` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_001_pure_annotation`
- `1000_PURITY/1002_inline_proc` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_002_inline_proc`
- `1000_PURITY/1003_flow_purity` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_003_flow_purity`
- `1000_PURITY/1004_transitive_pure` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_004_transitive_pure`
- `1000_PURITY/1005_transitive_impure` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_005_transitive_impure`
- `1000_PURITY/1006_event_purity` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_006_event_purity`
- `1000_PURITY/1007_cyclic_calls` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_007_cyclic_calls`
- `1000_PURITY/1008_mixed_impls` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_008_mixed_impls`
- `1000_PURITY/1009_subflow_pure` → `400_RUNTIME_FEATURES/410_PURITY_CHECKING/410_009_subflow_pure`

## Bugs (9100 → 520)
- `9100_BUGS/*` → `500_INTEGRATION_TESTING/520_BUG_REPRODUCTION/520_*`

## Examples (9900 → 920)
- `9900_EXAMPLES/*` → `900_EXAMPLES_SHOWCASE/920_DEMO_APPLICATIONS/920_*`

## Language Shootout (2100 → 910)
- `2100_LANGUAGE_SHOOTOUT/*` → `900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/910_*`
EOF

echo "${GREEN}✅ Migration mapping created${NC}"

echo ""
echo "${YELLOW}⚠️  MANUAL MIGRATION REQUIRED${NC}"
echo "The script has created the new structure but cannot automatically migrate tests."
echo ""
echo "${BLUE}📋 Next Steps:${NC}"
echo "1. Review the mapping in MIGRATION_MAPPING.md"
echo "2. Manually move tests according to the mapping"
echo "3. Update any hardcoded references"
echo "4. Run './run_regression.sh' to verify"
echo "5. Remove old empty directories"
echo ""
echo "${GREEN}🎯 Ready for manual migration!${NC}"
