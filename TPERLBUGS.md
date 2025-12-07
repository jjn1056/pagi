# Template::EmbeddedPerl Bugs

## Bug 1: Comparison operators `<` and `>` in multi-line code blocks cause parse errors

**Version:** Template::EmbeddedPerl 0.001014

**Description:**
When using `<` or `>` comparison operators inside a multi-line `<% %>` code block,
the parser/compiler misinterprets them, causing "Unterminated <> operator" errors.

**Error Message:**
```
Internal Server Error: Unterminated <> operator at unknown line 6

5:     my $show_add = $count < $max_options;
6: %>
7: <div class="options-fields">
```

Also fails with `>`:
```
Internal Server Error: Unterminated <> operator at unknown line 8

7:     my $show_add = $max_options > $count;
8: %>
9: <div class="options-fields">
```

**Minimal Reproduction:**
```perl
use Template::EmbeddedPerl;

# This FAILS - multi-line block with < operator
my $template_bad = <<'TEMPLATE';
<%
    my $count = 3;
    my $max = 6;
    my $show = $count < $max;
%>
<div>Show: <%= $show %></div>
TEMPLATE

# This also FAILS - multi-line block with > operator
my $template_also_bad = <<'TEMPLATE';
<%
    my $count = 3;
    my $max = 6;
    my $show = $max > $count;
%>
<div>Show: <%= $show %></div>
TEMPLATE

my $ep = Template::EmbeddedPerl->new();
my $compiled = $ep->from_string($template_bad);
my $output = $compiled->render({});  # Dies here
print $output;
```

**Expected:** Template renders with `$show` being true (1)

**Actual:** Error: "Unterminated <> operator"

**Analysis:**
The `<` and `>` characters in comparison operators appear to interfere with the
template parser's detection of `<%` and `%>` delimiters. This seems to only affect
multi-line code blocks where the closing `%>` is on a different line than the
comparison operator.

**Workarounds:**

1. Use `<=` or `>=` with adjusted values:
   ```perl
   my $show = $count <= 5;  # instead of $count < 6
   my $show = $count >= 1;  # instead of $count > 0
   ```

2. Use `!=` or `==` where possible:
   ```perl
   my $show = $count != 6;  # if you just need "not equal to max"
   ```

3. Use `unless` with opposite condition:
   ```perl
   <% unless ($count >= $max) { %>  # instead of if ($count < $max)
   ```

4. Single-line code blocks (may work):
   ```perl
   <% my $show = $count < $max; %>
   ```

5. Pass computed values from controller instead of comparing in template.

**Affected Code Patterns:**
Any `<` or `>` comparison inside multi-line `<% %>` blocks.
