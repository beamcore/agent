# Plan: Achieving Parity with Earendil's Edit Tool

## Overview

This document outlines a step-by-step plan to bring `Beamcore.Agent.Tools.Edit` to feature and reliability parity with the [Earendil-Works PI edit tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/edit.ts).

The current Beamcore implementation has several critical gaps that can lead to file corruption, particularly around line ending handling, BOM support, and whitespace normalization. This plan addresses these issues systematically.

---

## Phase 1: Critical Bug Fixes (Priority: P0)

### 1.1 Fix Line Ending Handling
**Problem:** `apply_exact_replacement` does byte-level string slicing without normalizing `new_string` to match the file's line endings.

**Tasks:**
- [ ] Modify `apply_exact_replacement/6` to normalize `new_string` line endings to match the file's detected line ending before replacement
- [ ] Ensure `apply_normalized_replacement/7` also respects the file's line ending convention
- [ ] Add test cases for CRLF files with LF replacement strings and vice versa

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Files with `\r\n` line endings maintain them after edit
- Files with `\n` line endings maintain them after edit
- Mixed line ending files are handled gracefully

---

### 1.2 Add BOM (Byte Order Mark) Support
**Problem:** No handling of UTF-8 BOM (`\uFEFF`), causing offset miscalculations and potential corruption.

**Tasks:**
- [ ] Add `strip_bom/1` function to extract and preserve BOM
- [ ] Modify `execute/1` to strip BOM before processing
- [ ] Modify both `apply_exact_replacement/6` and `apply_normalized_replacement/7` to prepend BOM to new content
- [ ] Add test cases for files with and without BOM

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Files with BOM maintain it after edit
- Files without BOM are not affected
- BOM is not included in match calculations

---

### 1.3 Add Change Detection
**Problem:** Files are written even when content hasn't changed, wasting I/O and triggering unnecessary file watchers.

**Tasks:**
- [ ] Add content comparison before file write in both `apply_exact_replacement/6` and `apply_normalized_replacement/7`
- [ ] Return appropriate error message when no changes would be made

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- No file write occurs when old and new content are identical
- Clear error message returned for no-op edits

---

## Phase 2: Matching Robustness Improvements (Priority: P1)

### 2.1 Improve Whitespace Normalization
**Problem:** Current `normalize_line/1` uses `String.trim()` which removes leading whitespace, breaking indented code matching. Also lacks Unicode normalization.

**Tasks:**
- [ ] Change `normalize_line/1` to only trim trailing whitespace (like Earendil's `trimEnd()`)
- [ ] Add Unicode NFKC normalization to handle equivalent Unicode characters
- [ ] Add smart quote normalization (`'`, `"` variants)
- [ ] Add dash/hyphen normalization
- [ ] Add special space character normalization

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Indented code blocks can be matched reliably
- Unicode equivalent characters are treated as matches
- Smart quotes and special dashes don't prevent matching

---

### 2.2 Fix Ambiguous Match Detection
**Problem:** Ambiguity checking is only done for exact substring matches, not for normalized matches. Also, the tolerance range logic can miss occurrences outside the range.

**Tasks:**
- [ ] Create a unified `count_occurrences/2` function that works across both exact and normalized matching
- [ ] Apply ambiguity checking consistently for all match types
- [ ] Check for ambiguity across the entire file, not just within search ranges

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- All ambiguous matches are detected regardless of matching strategy
- Error messages clearly indicate all occurrence locations

---

### 2.3 Simplify Matching Strategy
**Problem:** Current flow tries exact match, then falls back to normalized line match, which can lead to inconsistent behavior.

**Tasks:**
- [ ] Adopt Earendil's approach: normalize all content to LF first, then try exact match, then fuzzy match
- [ ] Ensure all matching happens in the same "space" (normalized or original)
- [ ] Remove the complex line-based normalized matching in favor of content-based matching

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Matching is more predictable and consistent
- Fewer false negatives (missed matches)
- Clearer error messages

---

## Phase 3: Architectural Improvements (Priority: P2)

### 3.1 Support Multiple Edits Per Call
**Problem:** Current implementation only supports single edits. Earendil supports multiple non-overlapping edits in one call.

**Tasks:**
- [ ] Modify function spec to accept `edits` array parameter (while maintaining backward compatibility with single edit)
- [ ] Implement overlapping edit detection
- [ ] Apply edits in reverse order to maintain offset stability
- [ ] Update error messages to reference specific edit indices

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Multiple non-overlapping edits can be applied in one call
- Overlapping edits are rejected with clear error messages
- Offsets remain stable across multiple edits

---

### 3.2 Add File Mutation Queue
**Problem:** No protection against concurrent edits to the same file.

**Tasks:**
- [ ] Implement a simple in-memory mutation queue using `Agent` or `GenServer`
- [ ] Acquire lock before reading/writing file
- [ ] Release lock after operation completes
- [ ] Handle lock timeouts gracefully

**Files to create/modify:**
- `lib/agent/tools/file_mutation_queue.ex` (new)
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Concurrent edits to the same file are serialized
- No race conditions between read-modify-write operations
- Clear error messages for lock timeouts

---

### 3.3 Remove Complex Indentation Adjustment
**Problem:** The `adjust_indent/6` function is complex and can introduce bugs. Earendil requires exact matches including whitespace.

**Tasks:**
- [ ] Remove `adjust_indent/6` and related logic
- [ ] Require `old_string` to match exactly, including all whitespace and indentation
- [ ] Update documentation to clarify exact match requirements
- [ ] Update error messages to guide users on providing exact matches

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Simpler, more predictable behavior
- Fewer edge cases and bugs
- Clearer expectations for users

---

## Phase 4: Enhanced Error Reporting (Priority: P2)

### 4.1 Improve Error Messages
**Problem:** Current error messages are good but could be more helpful.

**Tasks:**
- [ ] Add file path to all error messages
- [ ] Include edit index for multi-edit scenarios
- [ ] Provide more context in "not found" errors (show nearby lines)
- [ ] Add suggestions for common issues (line endings, whitespace, etc.)

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Error messages are actionable and informative
- Users can easily diagnose matching failures

---

### 4.2 Add Diff Output
**Problem:** Current implementation doesn't provide diff output like Earendil does.

**Tasks:**
- [ ] Add diff generation for successful edits
- [ ] Include diff in return value or as optional output
- [ ] Consider adding unified patch format support

**Files to modify:**
- `lib/agent/tools/edit.ex`

**Success criteria:**
- Users can see what changed in their files
- Diffs are available for logging/auditing

---

## Phase 5: Testing and Validation (Priority: P0-P2)

### 5.1 Unit Tests
**Tasks:**
- [ ] Add tests for BOM handling
- [ ] Add tests for CRLF vs LF line ending preservation
- [ ] Add tests for Unicode normalization
- [ ] Add tests for smart quote/dash normalization
- [ ] Add tests for ambiguous match detection
- [ ] Add tests for no-change detection
- [ ] Add tests for multi-edit scenarios
- [ ] Add tests for overlapping edit rejection
- [ ] Add tests for concurrent edit serialization

**Files to create/modify:**
- `test/agent/tools/edit_test.exs`

---

### 5.2 Integration Tests
**Tasks:**
- [ ] Test with real files of various types (source code, text, etc.)
- [ ] Test with various encodings and line endings
- [ ] Test edge cases (empty files, very large files, etc.)

---

### 5.3 Property-Based Tests
**Tasks:**
- [ ] Add property tests to verify that edits don't corrupt files
- [ ] Verify that line endings are preserved
- [ ] Verify that content outside edit regions is unchanged

---

## Implementation Order Recommendation

To minimize risk and maximize value, implement in this order:

1. **Phase 1.1: Line Ending Fix** (Highest risk of corruption)
2. **Phase 1.2: BOM Support** (High risk of corruption)
3. **Phase 1.3: Change Detection** (Low risk, quick win)
4. **Phase 2.1: Whitespace Normalization** (Improves reliability)
5. **Phase 2.2: Ambiguous Match Detection** (Improves safety)
6. **Phase 2.3: Simplify Matching Strategy** (Improves consistency)
7. **Phase 3.1: Multiple Edits** (Feature enhancement)
8. **Phase 3.2: Mutation Queue** (Robustness improvement)
9. **Phase 3.3: Remove Indentation Adjustment** (Simplification)
10. **Phase 4: Enhanced Error Reporting** (UX improvement)
11. **Phase 5: Testing** (Ongoing, but final validation)

---

## Success Metrics

- [ ] Zero file corruption incidents in test suite
- [ ] All Earendil edit tool test cases pass (when adapted to Elixir)
- [ ] 100% line ending preservation across all test cases
- [ ] 100% BOM preservation across all test cases
- [ ] Clear, actionable error messages for all failure modes
- [ ] Performance comparable to current implementation

---

## Estimated Effort

| Phase | Estimated Time | Complexity |
|-------|---------------|------------|
| Phase 1 (Critical Fixes) | 1-2 days | Medium |
| Phase 2 (Matching Improvements) | 2-3 days | Medium |
| Phase 3 (Architectural) | 3-5 days | High |
| Phase 4 (Error Reporting) | 1 day | Low |
| Phase 5 (Testing) | 2-3 days | Medium |
| **Total** | **9-14 days** | - |

---

## Dependencies

- No new external dependencies required
- May need to add `Unicode.transform/2` for NFKC normalization (part of Elixir standard library)

---

## Notes

1. **Backward Compatibility:** Maintain the current function signature and behavior where possible. The `edits` array can be added as an alternative to the current single-edit parameters.

2. **Performance:** The normalization steps add some overhead, but should be negligible for typical file sizes. Benchmark if needed.

3. **Documentation:** Update module documentation to reflect new capabilities and requirements.

4. **Migration:** Consider a deprecation path for the old single-edit interface if switching to multi-edit as primary.
