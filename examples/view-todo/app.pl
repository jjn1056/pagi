#!/usr/bin/env perl

# =============================================================================
# Todo App Example - Handler-based version
#
# A complete TodoMVC-style application demonstrating:
# - PAGI::Simple subclass with init() and routes()
# - Handler classes for organizing routes
# - #method syntax for route handlers
# - Middleware chains (#load => #show)
# - htmx for SPA-like interactions
# - Valiant forms for validation
# - Service layer for data operations
# - SSE for live updates
#
# Run with: pagi-server --app examples/view-todo/app.pl
# =============================================================================

use strict;
use warnings;

use lib 'lib';
use lib 'examples/view-todo/lib';
use TodoApp;

TodoApp->new->to_app;
