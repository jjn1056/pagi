# Plan: SSE Notification When Watched Poll Is Deleted

## Goal
When a poll is deleted while someone is watching it via SSE, show a "deleted" message in-place with a link back to the poll list.

## Approach
- Use `{ action => 'deleted' }` hashref for the publish message
- Create a partial template `polls/_deleted.html.ep` for the deleted message
- Update SSE callback to detect deletion and send `deleted` event
- Add `sse-swap="deleted"` listener in watch template

---

## Steps

### Step 1: Run baseline tests
- Run existing tests to establish baseline
- Verify poll demo app syntax is valid

### Step 2: Create the deleted partial template
- Create `examples/simple-17-htmx-poll/templates/polls/_deleted.html.ep`
- Simple card showing "This poll has been deleted" with link to home

### Step 3: Update SSE callback to handle deletion
- Modify the subscribe callback in `/polls/:id/live` route
- Check if message is a hashref with `action => 'deleted'`
- If so, render the `_deleted` partial and send as `deleted` event
- Otherwise, handle as normal vote update

### Step 4: Update delete handler to publish notification
- In `DELETE /polls/:id` route, before or after deletion
- Publish `{ action => 'deleted' }` to `poll:$id` channel

### Step 5: Update watch template to listen for deleted event
- Add `sse-swap="deleted"` div to receive deletion notification
- Can be same container or sibling to the vote swap

### Step 6: Test the changes manually
- Verify app syntax is still valid
- Describe manual test scenario

### Step 7: Run full test suite
- Run all PAGI::Simple tests to ensure no regressions

### Step 8: Commit changes
- Commit with descriptive message

---

## Files to modify/create

1. **Create**: `examples/simple-17-htmx-poll/templates/polls/_deleted.html.ep`
2. **Modify**: `examples/simple-17-htmx-poll/app.pl` (SSE callback + delete handler)
3. **Modify**: `examples/simple-17-htmx-poll/templates/polls/watch.html.ep` (add deleted listener)

## Testing approach
- This is demo app code, not library code, so no unit tests needed
- Manual verification that the feature works
- Run full test suite to ensure no regressions in core library
