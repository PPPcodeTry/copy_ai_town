#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
export AI_TOWN_PROVIDER_TEST_NO_NETWORK=1
export AI_TOWN_ISOLATED_TEST_SCRIPT="res://tests/historical_save_migration_story_test.gd"
export AI_TOWN_ISOLATED_PASS_MARKER="HISTORICAL_SAVE_MIGRATION_STORY_PASS"
export AI_TOWN_ISOLATED_TIMEOUT_SECONDS="${AI_TOWN_HISTORICAL_MIGRATION_TIMEOUT_SECONDS:-600}"
export AI_TOWN_ISOLATED_QA_PREFIX="ai-town-historical-migration"
export AI_TOWN_ISOLATED_TEMP_PREFIX="ai-town-historical-migration"
export AI_TOWN_ISOLATED_FAILURE_MARKER="HISTORICAL_SAVE_MIGRATION_STORY_FAIL"
export AI_TOWN_ISOLATED_SUCCESS_MARKER="HISTORICAL_SAVE_MIGRATION_STORY_VERIFIED"
export AI_TOWN_ISOLATED_FIXTURE_ROOT="$script_dir/fixtures/historical_saves/beta2"
export AI_TOWN_ISOLATED_ALLOWED_ERROR_PATTERN='a^'

exec "$script_dir/run_isolated_formal_entry_story.sh"
