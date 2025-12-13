# PAGI::Simple Component System Specification

## Overview

This document explores patterns for organizing routes and business logic in PAGI::Simple applications as they grow beyond simple single-file apps. It presents three approaches with detailed analysis, culminating in a recommendation for a Component-based pattern that aligns with PAGI's htmx-first philosophy.

## Problem Statement

As PAGI::Simple applications grow, the single-file `app.pl` approach becomes unwieldy:

```perl
# Current: 244 lines for a simple Todo app
$app->get('/' => sub ($c) { ... });
$app->post('/todos' => async sub ($c) { ... });
$app->patch('/todos/:id/toggle' => async sub ($c) { ... });
$app->delete('/todos/:id' => async sub ($c) { ... });
# ... 15+ more routes
```

**Pain points:**
- All routes in one file becomes hard to navigate
- Related functionality scattered (e.g., todo CRUD across multiple route definitions)
- Difficult to test individual handlers
- Code reuse between similar handlers is awkward
- No clear organization pattern for teams

## Research: Existing Patterns

### Pattern 1: Traditional MVC Controllers (Rails, Mojolicious, Catalyst)

**Mojolicious Example:**
```perl
# lib/MyApp/Controller/Todos.pm
package MyApp::Controller::Todos;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($self) {
    $self->render(todos => $self->app->model->all);
}

sub create ($self) {
    my $todo = $self->app->model->create($self->param('title'));
    $self->redirect_to('index');
}
```

```perl
# Routing in app
$r->get('/todos')->to('Todos#index');
$r->post('/todos')->to('Todos#create');
```

**Characteristics:**
- Controller class groups related actions
- Routes explicitly map to `Controller#action`
- Controller receives context/request object
- Separation between routing and handling

### Pattern 2: RESTful Resources (Rails)

```ruby
# Rails routes.rb
resources :todos do
  member do
    patch :toggle
  end
  collection do
    post :clear_completed
  end
end
```

Auto-generates:
| HTTP Verb | Path | Controller#Action |
|-----------|------|-------------------|
| GET | /todos | todos#index |
| POST | /todos | todos#create |
| GET | /todos/:id | todos#show |
| PATCH | /todos/:id | todos#update |
| DELETE | /todos/:id | todos#destroy |
| PATCH | /todos/:id/toggle | todos#toggle |
| POST | /todos/clear_completed | todos#clear_completed |

**Characteristics:**
- Convention over configuration
- Minimal route definitions
- Enforces REST semantics
- Controller discovered by convention

### Pattern 3: Operations/Commands (Trailblazer, CQRS)

```ruby
# Trailblazer Operation
class Todo::Create < Trailblazer::Operation
  step :validate
  step :persist
  step :notify

  def validate(ctx, params:, **)
    ctx[:todo] = Todo.new(params)
    ctx[:todo].valid?
  end

  def persist(ctx, todo:, **)
    todo.save
  end
end
```

**Characteristics:**
- One class per action (not per resource)
- Railway pattern: success/failure tracks
- Explicit step-by-step flow
- Highly testable, composable
- Each operation is self-contained

### Pattern 4: Component-Based (Phoenix LiveView, Laravel Livewire)

```elixir
# Phoenix LiveView
defmodule TodoLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, todos: Todos.list())}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    Todos.toggle(id)
    {:noreply, assign(socket, todos: Todos.list())}
  end

  def render(assigns) do
    ~H"""
    <div class="todo-list">
      <%= for todo <- @todos do %>
        <div phx-click="toggle" phx-value-id={todo.id}>...</div>
      <% end %>
    </div>
    """
  end
end
```

**Characteristics:**
- Component IS the controller AND view
- Handles its own events/actions
- Re-renders itself after state changes
- Perfect for reactive/partial-update UIs
- Self-contained, highly cohesive

---

## Proposed Solutions for PAGI::Simple

### Option 1: Controllers

**Implementation:**

```perl
# lib/TodoApp/Controller/Todos.pm
package TodoApp::Controller::Todos;
use parent 'PAGI::Simple::Controller';
use experimental 'signatures';
use Future::AsyncAwait;

sub index ($self, $c) {
    my $todos = $c->service('Todo');
    $c->render('index',
        todos    => [$todos->all],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'home',
    );
}

async sub create ($self, $c) {
    my $todos = $c->service('Todo');
    my $data = (await $c->structured_body)
        ->namespace('todo')
        ->permitted('title')
        ->to_hash;

    my $todo = $todos->build($data);

    if ($todos->save($todo)) {
        $c->hx_trigger('todoAdded');
        await $c->render_or_redirect('/', 'todos/_form',
            todo => $todos->new_todo);
    } else {
        $c->render('todos/_form', todo => $todo);
    }
}

async sub toggle ($self, $c) {
    my $id = $c->param('id');
    my $todo = $c->service('Todo')->toggle($id);

    return $c->status(404)->text('Not found') unless $todo;

    $c->hx_trigger('todoToggled');
    await $c->render_or_redirect('/', 'todos/_item', todo => $todo);
}

async sub destroy ($self, $c) {
    my $id = $c->param('id');
    return $c->status(404)->text('Not found')
        unless $c->service('Todo')->delete($id);

    $c->hx_trigger('todoDeleted');
    await $c->empty_or_redirect('/');
}

1;
```

**Routing in app.pl:**

```perl
# Explicit routing
$app->get('/' => 'Todos#index')->name('home');
$app->post('/todos' => 'Todos#create')->name('todos_create');
$app->patch('/todos/:id/toggle' => 'Todos#toggle')->name('todo_toggle');
$app->delete('/todos/:id' => 'Todos#destroy')->name('todo_delete');

# Or with route groups
$app->controller('Todos' => sub ($r) {
    $r->get('/' => 'index')->name('home');
    $r->post('/todos' => 'create');
    $r->patch('/todos/:id/toggle' => 'toggle');
    $r->delete('/todos/:id' => 'destroy');
});
```

**Base class:**

```perl
# lib/PAGI/Simple/Controller.pm
package PAGI::Simple::Controller;
use experimental 'signatures';

sub new ($class, %args) {
    return bless \%args, $class;
}

# Subclasses can override for before-action hooks
sub before_action ($self, $c, $action) { 1 }

# Called by router to dispatch
sub dispatch ($self, $c, $action) {
    return unless $self->before_action($c, $action);
    my $method = $self->can($action)
        or die "Unknown action: $action";
    return $self->$method($c);
}

1;
```

**Auto-discovery pattern (like Services):**

```perl
# In PAGI::Simple
sub _discover_controllers ($self) {
    my $namespace = $self->{_namespace};
    my $controller_ns = "${namespace}::Controller";

    # Use Module::Pluggable to find controller classes
    # Similar pattern to _discover_services()
}
```

**Pros:**
- Familiar pattern (Rails, Mojolicious, Catalyst)
- Clear separation of concerns
- Easy to test controller methods
- Groups related actions logically

**Cons:**
- More files to manage
- Indirection between route and handler
- Still need explicit route definitions

---

### Option 2: RESTful Resources

**Implementation:**

```perl
# app.pl
$app->resources('todos' => sub ($r) {
    # Auto-generates standard CRUD routes
    # Additional custom routes:
    $r->member->patch('/toggle');      # PATCH /todos/:id/toggle
    $r->collection->post('/clear');    # POST /todos/clear
});

# Nested resources
$app->resources('projects' => sub ($r) {
    $r->resources('tasks');  # /projects/:project_id/tasks
});
```

**Generated routes for `resources('todos')`:**

| Method | Path | Action | Route Name |
|--------|------|--------|------------|
| GET | /todos | index | todos |
| GET | /todos/new | new | todos_new |
| POST | /todos | create | todos_create |
| GET | /todos/:id | show | todo |
| GET | /todos/:id/edit | edit | todo_edit |
| PATCH | /todos/:id | update | todo_update |
| DELETE | /todos/:id | destroy | todo_destroy |

**Controller convention:**

```perl
# lib/TodoApp/Controller/Todos.pm
package TodoApp::Controller::Todos;
use parent 'PAGI::Simple::Controller';

# Standard RESTful actions
sub index ($self, $c) { ... }
sub show ($self, $c) { ... }
sub new ($self, $c) { ... }      # Form for creating
sub create ($self, $c) { ... }
sub edit ($self, $c) { ... }     # Form for editing
sub update ($self, $c) { ... }
sub destroy ($self, $c) { ... }

# Custom actions from member/collection
sub toggle ($self, $c) { ... }
sub clear ($self, $c) { ... }

1;
```

**Implementation in PAGI::Simple:**

```perl
sub resources ($self, $name, $block = undef) {
    my $controller = ucfirst($name);  # 'todos' -> 'Todos'
    my $singular = $name =~ s/s$//r;  # 'todos' -> 'todo'

    # Standard routes
    $self->get("/$name" => "$controller#index")->name($name);
    $self->get("/$name/new" => "$controller#new")->name("${name}_new");
    $self->post("/$name" => "$controller#create")->name("${name}_create");
    $self->get("/$name/:id" => "$controller#show")->name($singular);
    $self->get("/$name/:id/edit" => "$controller#edit")->name("${singular}_edit");
    $self->patch("/$name/:id" => "$controller#update")->name("${singular}_update");
    $self->delete("/$name/:id" => "$controller#destroy")->name("${singular}_destroy");

    # Custom routes via block
    if ($block) {
        my $resource_router = PAGI::Simple::ResourceRouter->new(
            app => $self,
            name => $name,
            controller => $controller,
        );
        $block->($resource_router);
    }

    return $self;
}
```

**Pros:**
- Minimal boilerplate
- Enforces consistent REST conventions
- Familiar to Rails developers
- Auto-generates route names

**Cons:**
- Magic can be confusing
- Less flexible for non-CRUD patterns
- May generate unused routes

---

### Option 3: Components (Recommended for htmx-first apps)

**Philosophy:**

In traditional MVC, the view is passive - it receives data and renders. The controller orchestrates. But with htmx, views are active participants - they trigger actions and expect partial re-renders.

The Component pattern embraces this: **a component IS its view AND its controller**. It knows:
1. How to render itself
2. What actions it can handle
3. How to re-render after actions

This is the mental model htmx developers already have - we're just making it explicit in the code structure.

**Implementation:**

```perl
# lib/TodoApp/Component/TodoList.pm
package TodoApp::Component::TodoList;
use parent 'PAGI::Simple::Component';
use experimental 'signatures';
use Future::AsyncAwait;

# Component configuration
sub config ($class) {
    return {
        # Base path for this component's actions
        path => '/todos',

        # Template directory (defaults to component name)
        template_dir => 'todos',

        # Default template for render()
        template => '_list',
    };
}

# Main render method - called via <%= component('TodoList', filter => 'all') %>
sub render ($self, $c, %args) {
    my $filter = $args{filter} // 'all';
    my $todos = $c->service('Todo');

    my @items = $filter eq 'active'    ? $todos->active
              : $filter eq 'completed' ? $todos->completed
              :                          $todos->all;

    $c->render($self->template,
        todos  => \@items,
        active => $todos->active_count,
        filter => $filter,
    );
}

# Actions - auto-routed to POST /todos/toggle/:id
async sub action_toggle ($self, $c) {
    my $id = $c->param('id');
    my $todo = $c->service('Todo')->toggle($id);

    return $c->status(404)->text('Not found') unless $todo;

    $c->hx_trigger('todoToggled');

    # Re-render just the affected item
    $c->render('_item', todo => $todo);
}

async sub action_create ($self, $c) {
    my $todos = $c->service('Todo');
    my $data = (await $c->structured_body)
        ->namespace('todo')
        ->permitted('title')
        ->to_hash;

    my $todo = $todos->build($data);

    if ($todos->save($todo)) {
        $c->hx_trigger('todoAdded');
        $c->render('_form', todo => $todos->new_todo);
    } else {
        $c->render('_form', todo => $todo);
    }
}

async sub action_destroy ($self, $c) {
    my $id = $c->param('id');
    return $c->status(404)->text('Not found')
        unless $c->service('Todo')->delete($id);

    $c->hx_trigger('todoDeleted');
    await $c->empty_or_redirect('/');
}

async sub action_clear_completed ($self, $c) {
    $c->service('Todo')->clear_completed;
    $c->hx_trigger('todosCleared');
    $self->render($c);  # Re-render entire component
}

1;
```

**Template integration:**

```html
<!-- templates/index.html.ep -->
<section class="todoapp">
  <header>
    <%= component('TodoForm') %>
  </header>

  <main>
    <%= component('TodoList', filter => $v->filter) %>
  </main>

  <footer>
    <%= component('TodoFooter', filter => $v->filter) %>
  </footer>
</section>
```

```html
<!-- templates/todos/_list.html.ep -->
<section class="todo-list" id="todo-list">
  <% for my $todo (@{$v->todos}) { %>
    <%= include('_item', todo => $todo) %>
  <% } %>
</section>
```

```html
<!-- templates/todos/_item.html.ep -->
<li class="todo-item" id="todo-<%= $v->todo->id %>">
  <input type="checkbox"
         <%= checked_if($v->todo->completed) %>
         hx-post="<%= component_action('TodoList', 'toggle', id => $v->todo->id) %>"
         hx-target="#todo-<%= $v->todo->id %>"
         hx-swap="outerHTML">

  <span><%= $v->todo->title %></span>

  <button hx-delete="<%= component_action('TodoList', 'destroy', id => $v->todo->id) %>"
          hx-target="#todo-<%= $v->todo->id %>"
          hx-swap="delete">
    Delete
  </button>
</li>
```

**Base class:**

```perl
# lib/PAGI/Simple/Component.pm
package PAGI::Simple::Component;
use experimental 'signatures';

sub new ($class, %args) {
    return bless {
        app => $args{app},
        %{$class->config // {}},
    }, $class;
}

sub config ($class) { {} }

sub template ($self) {
    return $self->{template} // die "No template defined";
}

sub template_dir ($self) {
    return $self->{template_dir} // $self->_default_template_dir;
}

sub _default_template_dir ($self) {
    my $class = ref($self) || $self;
    $class =~ s/.*::Component:://;
    $class =~ s/::/_/g;
    return lc($class);
}

# Override in subclass
sub render ($self, $c, %args) {
    die "Component must implement render()";
}

# Dispatch action
sub dispatch_action ($self, $c, $action) {
    my $method = "action_$action";
    my $handler = $self->can($method)
        or die "Unknown action: $action";
    return $self->$handler($c);
}

# Get all available actions
sub actions ($self) {
    my @methods = grep { /^action_/ } keys %{ref($self) . '::'};
    return map { s/^action_//; $_ } @methods;
}

1;
```

**Auto-discovery and routing:**

```perl
# In PAGI::Simple
sub _discover_components ($self) {
    my $namespace = $self->{_namespace};
    my $component_ns = "${namespace}::Component";

    # Find all component classes
    for my $class ($self->_find_classes($component_ns)) {
        my $component = $class->new(app => $self);
        my $config = $class->config // {};
        my $path = $config->{path} // $self->_path_for_component($class);

        # Register routes for each action
        for my $action ($component->actions) {
            my $route_path = $self->_action_path($path, $action);
            my $handler = sub ($c) {
                $component->dispatch_action($c, $action);
            };

            # Determine HTTP method from action name
            my $method = $self->_method_for_action($action);
            $self->$method($route_path => $handler);
        }

        $self->{_components}{$class} = $component;
    }
}

sub _method_for_action ($self, $action) {
    return 'delete' if $action =~ /^destroy|delete|remove/;
    return 'patch'  if $action =~ /^update|toggle|patch/;
    return 'get'    if $action =~ /^show|edit|list|index/;
    return 'post';  # Default
}

sub _action_path ($self, $base, $action) {
    # action_toggle -> /base/toggle
    # action_destroy -> /base/:id (DELETE)
    # action_show -> /base/:id (GET)
    return "$base/$action";  # Simplified; real impl handles :id
}
```

**Template helpers:**

```perl
# In View helpers
sub helper_component ($self, $ctx, $name, %args) {
    my $app = $ctx->{app};
    my $class = $app->{_namespace} . "::Component::$name";
    my $component = $app->{_components}{$class}
        or die "Unknown component: $name";

    return $component->render($ctx->{c}, %args);
}

sub helper_component_action ($self, $ctx, $name, $action, %params) {
    my $app = $ctx->{app};
    my $class = $app->{_namespace} . "::Component::$name";
    my $config = $class->config // {};
    my $base = $config->{path} // '/' . lc($name);

    my $path = "$base/$action";

    # Add params to path
    for my $key (keys %params) {
        if ($path =~ /:$key\b/) {
            $path =~ s/:$key\b/$params{$key}/;
        } else {
            # Add as query param
            $path .= ($path =~ /\?/) ? '&' : '?';
            $path .= "$key=$params{$key}";
        }
    }

    return $path;
}
```

**Pros:**
- Perfect alignment with htmx mental model
- Self-contained, highly cohesive units
- Each component fully testable in isolation
- No separation between "controller" and "view" logic
- Actions automatically become routes
- Natural for partial re-renders

**Cons:**
- Novel pattern - learning curve
- May not suit all use cases (API-only, non-htmx)
- Components may grow large if not decomposed

---

## Comparison Matrix

| Aspect | Controllers | Resources | Components |
|--------|-------------|-----------|------------|
| **Files per feature** | 1 controller | 1 controller | 1 component |
| **Route definitions** | Explicit | Auto-generated | Auto-generated |
| **htmx fit** | Good | Good | Excellent |
| **Testability** | Good | Good | Excellent |
| **Learning curve** | Low (familiar) | Low (familiar) | Medium |
| **Flexibility** | High | Medium | High |
| **Cohesion** | Medium | Medium | High |
| **Best for** | Traditional apps | CRUD APIs | htmx-first apps |

---

## Recommendation

For PAGI::Simple, I recommend **implementing Components as the primary pattern** with Controllers as a fallback for non-htmx use cases.

**Rationale:**
1. PAGI::Simple's identity is htmx-first; Components embrace this
2. The pattern makes partial re-renders a first-class concept
3. Aligns with modern frontend patterns (React, Vue, Svelte components)
4. Service layer already exists for shared business logic
5. Natural upgrade path from inline routes

**Migration path:**
1. Start with inline routes (current)
2. Extract to Components when routes grow
3. Use Controllers for API-only endpoints

---

## Open Questions

1. **Component state**: Should components be stateless (like now) or support per-request state?

2. **Nested components**: How do child components communicate with parents?

3. **Component inheritance**: Can TodoList extend BaseList?

4. **Async rendering**: Should `component()` helper return a Future for async render?

5. **Component testing**: What's the ideal test interface?

6. **SSE/WebSocket integration**: How do components handle real-time updates?

7. **Naming**: Is "Component" the right term, or something like "Action", "Handler", "Island"?

---

## Next Steps

1. [ ] Prototype `PAGI::Simple::Component` base class
2. [ ] Implement auto-discovery in PAGI::Simple
3. [ ] Add `component()` and `component_action()` template helpers
4. [ ] Convert Todo app to use Components
5. [ ] Write tests for component system
6. [ ] Document the pattern

---

## References

- [Mojolicious::Guides::Growing](https://docs.mojolicious.org/Mojolicious/Guides/Growing)
- [Rails Routing Guide](https://guides.rubyonrails.org/routing.html)
- [Trailblazer Operations](https://trailblazer.to/2.1/docs/operation/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Laravel Livewire](https://livewire.laravel.com/)
- [htmx Essays](https://htmx.org/essays/)
