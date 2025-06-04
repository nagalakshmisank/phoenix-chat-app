# Elixir/Phoenix Best Practices Guide for Developers

## Table of Contents
1. [Project Setup and Mix Package Management](#project-setup-and-mix-package-management)
2. [Git Branching Strategies](#git-branching-strategies)
3. [Test-Driven Development (TDD)](#test-driven-development-tdd)
4. [API Development Best Practices](#api-development-best-practices)
5. [CI/CD Pipeline Management](#cicd-pipeline-management)
6. [Essential Commands Reference](#essential-commands-reference)

---

## Project Types and Specialized Commands

### Umbrella Projects
Umbrella projects allow you to manage multiple applications in a single repository:

```bash
# Create umbrella project
mix new my_umbrella --umbrella
cd my_umbrella

# Add applications to umbrella
cd apps
mix new web_app --sup
mix phx.new api_app --api
mix new shared_lib

# Commands from umbrella root
mix deps.get                    # Install deps for all apps
mix test                        # Run tests for all apps
mix compile                     # Compile all apps
mix format                      # Format all apps

# Commands for specific apps
mix cmd --app web_app mix test  # Run tests for specific app
mix cmd --app api_app mix phx.server # Start specific app
```

### LiveView Projects
```bash
# Create LiveView project
mix phx.new my_live_app --live

# Generate LiveView components
mix phx.gen.live Blog Post posts title:string content:text published:boolean
mix phx.gen.live Accounts User users name:string email:string

# Generate LiveComponents
mix phx.gen.component Modal
mix phx.gen.component UserCard

# LiveView-specific testing
mix test test/my_live_app_web/live/
```

### OTP Applications
```bash
# Create GenServer application
mix new my_genserver_app --sup

# Generate GenServer
mix phx.gen.server UserCache

# Generate Supervisor
mix phx.gen.supervisor DynamicUserSupervisor

# Generate Agent
mix phx.gen.agent StateAgent
```

### API-Only Projects
```bash
# Create API-only Phoenix app
mix phx.new my_api --api

# Generate JSON resources
mix phx.gen.json Accounts User users name:string email:string
mix phx.gen.json Blog Post posts title:string content:text

# API testing commands
mix test test/my_api_web/controllers/
mix phx.routes                  # Show all API routes
```

---

## Project Setup and Mix Package Management

### Creating a New Phoenix Project

```bash
# Install Phoenix if you haven't already
mix archive.install hex phx_new

# Create a new Phoenix project
mix phx.new my_app --database postgres
cd my_app

# Install dependencies
mix deps.get

# Create and migrate database
mix ecto.create
mix ecto.migrate
```

### Managing Dependencies in mix.exs

Your `mix.exs` file is the heart of dependency management. Here's a well-structured example:

```elixir
defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_app,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {MyApp.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      # Phoenix Framework
      {:phoenix, "~> 1.7.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.6"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.19.0"},
      
      # JSON handling
      {:jason, "~> 1.2"},
      
      # Development and testing
      {:ex_machina, "~> 2.7.0", only: [:dev, :test]},
      {:excoveralls, "~> 0.10", only: :test},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      
      # Production
      {:plug_cowboy, "~> 2.5"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "test.coverage": ["coveralls.html"],
      quality: ["format", "credo --strict", "dialyzer"]
    ]
  end
end
```

### Comprehensive Mix Commands for Different Project Types

#### Project Creation Commands
```bash
# Standard Elixir application
mix new my_app
mix new my_app --sup                    # With supervision tree
mix new my_app --umbrella              # Umbrella project

# Phoenix applications
mix phx.new my_app                     # Full Phoenix app
mix phx.new my_app --api               # API-only (no HTML/CSS/JS)
mix phx.new my_app --live              # With Phoenix LiveView
mix phx.new my_app --no-ecto          # Without Ecto database
mix phx.new my_app --database mysql    # With MySQL instead of PostgreSQL

# OTP Applications
mix new my_gen_server --sup            # GenServer application
mix new my_supervisor --sup            # Supervisor tree application

# Libraries and Hex packages
mix new my_library --module MyLibrary  # Library project
```

#### Phoenix Generators
```bash
# Generate complete CRUD resources
mix phx.gen.html Accounts User users name:string email:string:unique
mix phx.gen.json Blog Post posts title:string content:text user_id:references:users
mix phx.gen.context Accounts User users name:string email:string

# Generate LiveView components
mix phx.gen.live Blog Post posts title:string content:text --web MyAppWeb

# Generate authentication system
mix phx.gen.auth Accounts User users

# Generate channels and sockets
mix phx.gen.channel Room
mix phx.gen.socket User

# Generate controllers and views
mix phx.gen.controller UserController
mix phx.gen.view UserView

# Generate presence
mix phx.gen.presence
```

#### Ecto Generators and Commands
```bash
# Generate migrations
mix ecto.gen.migration create_users
mix ecto.gen.migration add_email_to_users
mix ecto.gen.migration create_posts_table

# Generate schemas
mix phx.gen.schema Accounts.User users name:string email:string:unique

# Database operations
mix ecto.create                       # Create database
mix ecto.create -r MyApp.Repo         # Create for specific repo
mix ecto.drop                         # Drop database
mix ecto.migrate                      # Run pending migrations
mix ecto.migrate --step 1             # Run one migration
mix ecto.rollback                     # Rollback last migration
mix ecto.rollback --step 3            # Rollback 3 migrations
mix ecto.rollback --to 20210101000000 # Rollback to specific version
mix ecto.reset                        # Drop, create, and migrate
mix ecto.setup                        # Create, migrate, and seed

# Seeds and dumps
mix run priv/repo/seeds.exs           # Run seeds
mix ecto.dump                         # Dump database structure
mix ecto.load                         # Load database structure
```

#### Package Management Commands
```bash
# Dependencies
mix deps.get                          # Install dependencies
mix deps.get --only prod              # Install only production deps
mix deps.update --all                 # Update all dependencies
mix deps.update phoenix ecto          # Update specific packages
mix deps.clean --all                  # Clean all dependencies
mix deps.clean phoenix               # Clean specific dependency
mix deps.tree                        # Show dependency tree
mix deps.outdated                    # Check for outdated packages
mix deps.unlock --all                # Unlock all dependencies

# Hex package management
mix hex.info phoenix                  # Package information
mix hex.search phoenix               # Search for packages
mix hex.outdated                     # Check outdated hex packages
```

---

## Git Branching Strategies

### GitFlow for Elixir Projects

We recommend a simplified GitFlow strategy for Elixir/Phoenix projects:

```
main (production-ready code)
├── develop (integration branch)
│   ├── feature/user-authentication
│   ├── feature/api-endpoints
│   └── feature/admin-dashboard
├── hotfix/critical-bug-fix
└── release/v1.2.0
```

### Branch Naming Conventions

```bash
# Feature branches
feature/ticket-number-short-description
feature/AUTH-123-user-login
feature/API-456-user-endpoints

# Bug fixes
bugfix/ticket-number-description
bugfix/BUG-789-email-validation

# Hotfixes
hotfix/critical-issue-description
hotfix/security-patch-auth

# Release branches
release/version-number
release/v1.2.0
```

### Comprehensive Git Commands for Code Management

#### Branch Operations
```bash
# Create and manage branches
git branch                            # List local branches
git branch -a                         # List all branches (local + remote)
git branch -r                         # List remote branches
git branch feature/new-feature        # Create new branch
git checkout -b feature/new-feature   # Create and switch to new branch
git checkout feature/existing         # Switch to existing branch
git switch feature/existing           # Modern way to switch branches

# Delete branches
git branch -d feature/completed       # Delete merged branch (safe)
git branch -D feature/abandoned       # Force delete branch (unsafe)
git push origin --delete feature/old # Delete remote branch

# Rename branches
git branch -m old-name new-name       # Rename current branch
git branch -m feature/old feature/new # Rename any branch
```

#### Merging Strategies
```bash
# Fast-forward merge (linear history)
git checkout main
git merge feature/simple-fix

# No fast-forward merge (preserve branch history)
git checkout develop
git merge --no-ff feature/AUTH-123-user-login

# Squash merge (combine all commits into one)
git checkout main
git merge --squash feature/multiple-commits
git commit -m "feat: implement user authentication"

# Merge with custom commit message
git merge --no-ff -m "Merge feature: user authentication" feature/auth
```

#### Rebasing Operations
```bash
# Rebase feature branch on develop
git checkout feature/AUTH-123-user-login
git rebase develop

# Interactive rebase (edit commit history)
git rebase -i HEAD~3                  # Rebase last 3 commits
git rebase -i develop                 # Rebase on develop interactively

# Rebase and preserve merge commits
git rebase --preserve-merges develop

# Continue/abort rebase
git rebase --continue                 # After resolving conflicts
git rebase --abort                    # Cancel rebase operation
git rebase --skip                     # Skip current commit
```

#### Conflict Resolution
```bash
# When conflicts occur during merge/rebase
git status                            # See conflicted files
git diff                              # See conflict details
git add resolved_file.ex              # Mark conflict as resolved
git commit                            # Complete merge (for merge conflicts)
git rebase --continue                 # Continue rebase (for rebase conflicts)

# Tools for conflict resolution
git mergetool                         # Open merge tool
git diff --name-only --diff-filter=U # List conflicted files
git checkout --ours conflicted_file  # Keep "our" version
git checkout --theirs conflicted_file # Keep "their" version
```

#### Remote Repository Management
```bash
# Remote operations
git remote -v                         # List remotes
git remote add upstream https://github.com/original/repo.git
git remote remove origin             # Remove remote
git remote rename origin upstream    # Rename remote

# Fetch and pull operations
git fetch origin                      # Fetch from origin
git fetch --all                       # Fetch from all remotes
git pull origin develop              # Fetch and merge
git pull --rebase origin develop     # Fetch and rebase
git pull upstream main               # Pull from upstream

# Push operations
git push origin feature-branch       # Push branch to origin
git push -u origin feature-branch    # Push and set upstream
git push --force-with-lease          # Safe force push
git push --all                       # Push all branches
git push --tags                      # Push all tags
```

#### Advanced Git Operations
```bash
# Stashing changes
git stash                             # Stash current changes
git stash save "work in progress"     # Stash with message
git stash list                        # List all stashes
git stash pop                         # Apply and remove last stash
git stash apply stash@{2}            # Apply specific stash
git stash drop stash@{1}             # Delete specific stash
git stash clear                       # Delete all stashes

# Cherry-picking commits
git cherry-pick abc123def            # Apply specific commit
git cherry-pick abc123..def456       # Apply range of commits
git cherry-pick --no-commit abc123   # Apply without committing

# Reset operations
git reset HEAD~1                      # Undo last commit (keep changes)
git reset --soft HEAD~1              # Undo commit (keep staged)
git reset --hard HEAD~1              # Undo commit (lose changes)
git reset --hard origin/main         # Reset to remote state

# Tagging and releases
git tag v1.0.0                        # Create lightweight tag
git tag -a v1.0.0 -m "Release v1.0.0" # Create annotated tag
git tag -l "v1.*"                     # List tags matching pattern
git push origin v1.0.0               # Push specific tag
git push origin --tags               # Push all tags
git tag -d v1.0.0                    # Delete local tag
git push origin --delete v1.0.0     # Delete remote tag

# Log and history
git log --oneline                     # Compact log
git log --graph --oneline --all      # Visual branch history
git log --author="John Doe"          # Filter by author
git log --since="2 weeks ago"        # Filter by date
git log --grep="fix"                 # Filter by commit message
git log -p                           # Show patch/diff in log
git log --stat                       # Show file statistics

# Blame and bisect
git blame filename.ex                 # See who changed each line
git bisect start                      # Start bisect session
git bisect good v1.0                 # Mark known good commit
git bisect bad HEAD                   # Mark known bad commit
```

#### Git Workflow for Team Collaboration
```bash
# Daily workflow
git checkout develop
git pull origin develop              # Get latest changes
git checkout -b feature/TICKET-123   # Create feature branch
# ... make changes ...
git add .
git commit -m "feat: add user validation"
git push -u origin feature/TICKET-123

# Preparing for merge
git checkout develop
git pull origin develop              # Get latest develop
git checkout feature/TICKET-123
git rebase develop                   # Rebase on latest develop
git push --force-with-lease         # Update remote branch

#### Hotfix Workflow
```bash
# Emergency production fix
git checkout main
git pull origin main
git checkout -b hotfix/critical-security-fix

# Make critical changes
git add .
git commit -m "fix: resolve security vulnerability"

# Merge to main and develop
git checkout main
git merge --no-ff hotfix/critical-security-fix
git tag v1.0.1
git push origin main
git push origin v1.0.1

git checkout develop
git merge --no-ff hotfix/critical-security-fix
git push origin develop

# Clean up
git branch -d hotfix/critical-security-fix
git push origin --delete hotfix/critical-security-fix
```

#### Release Management Workflow
```bash
# Create release branch
git checkout develop
git pull origin develop
git checkout -b release/v1.2.0

# Prepare release (version bumps, changelog)
git add .
git commit -m "chore: prepare release v1.2.0"

# Merge to main
git checkout main
git pull origin main
git merge --no-ff release/v1.2.0
git tag -a v1.2.0 -m "Release version 1.2.0"
git push origin main
git push origin v1.2.0

# Merge back to develop
git checkout develop
git merge --no-ff release/v1.2.0
git push origin develop

# Clean up
git branch -d release/v1.2.0
git push origin --delete release/v1.2.0
```

#### Collaborative Conflict Resolution
```bash
# When pull request has conflicts
git checkout feature/conflicted-branch
git fetch origin
git rebase origin/develop

# If conflicts occur
git status                      # See conflicted files
# Edit files to resolve conflicts
git add resolved_file.ex
git rebase --continue

# Force push updated branch
git push --force-with-lease origin feature/conflicted-branch
```

### Pre-commit Hooks

Create a `.git/hooks/pre-commit` file:

```bash
#!/bin/sh
# Run tests before commit
mix test

if [ $? -ne 0 ]; then
  echo "Tests failed. Commit aborted."
  exit 1
fi

# Run code quality checks
mix format --check-formatted
mix credo --strict

if [ $? -ne 0 ]; then
  echo "Code quality checks failed. Commit aborted."
  exit 1
fi
```

---

## Test-Driven Development (TDD)

### TDD Cycle: Red-Green-Refactor

1. **Red**: Write a failing test
2. **Green**: Write minimal code to make it pass
3. **Refactor**: Improve code while keeping tests green

### Setting Up Test Environment

```elixir
# test/support/factory.ex
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  def user_factory do
    %MyApp.Accounts.User{
      email: sequence(:email, &"user#{&1}@example.com"),
      name: "John Doe",
      encrypted_password: Bcrypt.hash_pwd_salt("password123")
    }
  end

  def post_factory do
    %MyApp.Blog.Post{
      title: "Sample Post",
      content: "This is a sample post content",
      user: build(:user)
    }
  end
end
```

### Test Structure Example

```elixir
# test/my_app/accounts_test.exs
defmodule MyApp.AccountsTest do
  use MyApp.DataCase
  import MyApp.Factory

  alias MyApp.Accounts

  describe "create_user/1" do
    test "creates user with valid attributes" do
      user_attrs = %{
        email: "test@example.com",
        name: "Test User",
        password: "password123"
      }

      assert {:ok, user} = Accounts.create_user(user_attrs)
      assert user.email == "test@example.com"
      assert user.name == "Test User"
      assert Bcrypt.verify_pass("password123", user.encrypted_password)
    end

    test "returns error with invalid email" do
      user_attrs = %{
        email: "invalid-email",
        name: "Test User",
        password: "password123"
      }

      assert {:error, changeset} = Accounts.create_user(user_attrs)
      assert %{email: ["has invalid format"]} = errors_on(changeset)
    end

    test "returns error with short password" do
      user_attrs = %{
        email: "test@example.com",
        name: "Test User",
        password: "123"
      }

      assert {:error, changeset} = Accounts.create_user(user_attrs)
      assert %{password: ["should be at least 6 character(s)"]} = errors_on(changeset)
    end
  end

  describe "authenticate_user/2" do
    test "returns user with valid credentials" do
      user = insert(:user, email: "test@example.com")
      
      assert {:ok, authenticated_user} = 
        Accounts.authenticate_user("test@example.com", "password123")
      assert authenticated_user.id == user.id
    end

    test "returns error with invalid credentials" do
      insert(:user, email: "test@example.com")
      
      assert {:error, :invalid_credentials} = 
        Accounts.authenticate_user("test@example.com", "wrong_password")
    end
  end
end
```

### Testing Controllers

```elixir
# test/my_app_web/controllers/user_controller_test.exs
defmodule MyAppWeb.UserControllerTest do
  use MyAppWeb.ConnCase
  import MyApp.Factory

  describe "GET /api/users" do
    test "returns list of users", %{conn: conn} do
      user1 = insert(:user, name: "John Doe")
      user2 = insert(:user, name: "Jane Smith")

      conn = get(conn, Routes.user_path(conn, :index))

      assert json_response(conn, 200) == %{
        "data" => [
          %{"id" => user1.id, "name" => "John Doe", "email" => user1.email},
          %{"id" => user2.id, "name" => "Jane Smith", "email" => user2.email}
        ]
      }
    end
  end

  describe "POST /api/users" do
    test "creates user with valid data", %{conn: conn} do
      user_params = %{
        "name" => "New User",
        "email" => "new@example.com",
        "password" => "password123"
      }

      conn = post(conn, Routes.user_path(conn, :create), user: user_params)

      assert %{"id" => id} = json_response(conn, 201)["data"]
      assert MyApp.Repo.get(MyApp.Accounts.User, id)
    end

    test "returns error with invalid data", %{conn: conn} do
      user_params = %{
        "name" => "",
        "email" => "invalid-email"
      }

      conn = post(conn, Routes.user_path(conn, :create), user: user_params)

      assert json_response(conn, 422)["errors"] != %{}
    end
  end
end
```

---

## API Development Best Practices

### RESTful API Structure

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :authenticated_api do
    plug :api
    plug MyAppWeb.Plugs.RequireAuth
  end

  scope "/api/v1", MyAppWeb do
    pipe_through :api

    post "/auth/login", AuthController, :login
    post "/users", UserController, :create
  end

  scope "/api/v1", MyAppWeb do
    pipe_through :authenticated_api

    get "/users", UserController, :index
    get "/users/:id", UserController, :show
    put "/users/:id", UserController, :update
    delete "/users/:id", UserController, :delete

    resources "/posts", PostController, except: [:new, :edit]
  end
end
```

### Controller Best Practices

```elixir
# lib/my_app_web/controllers/user_controller.ex
defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller

  alias MyApp.Accounts
  alias MyApp.Accounts.User

  action_fallback MyAppWeb.FallbackController

  def index(conn, params) do
    users = Accounts.list_users(params)
    render(conn, "index.json", users: users)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, user} <- Accounts.get_user(id) do
      render(conn, "show.json", user: user)
    end
  end

  def create(conn, %{"user" => user_params}) do
    with {:ok, user} <- Accounts.create_user(user_params) do
      conn
      |> put_status(:created)
      |> render("show.json", user: user)
    end
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    with {:ok, user} <- Accounts.get_user(id),
         {:ok, updated_user} <- Accounts.update_user(user, user_params) do
      render(conn, "show.json", user: updated_user)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, user} <- Accounts.get_user(id),
         {:ok, _user} <- Accounts.delete_user(user) do
      send_resp(conn, :no_content, "")
    end
  end
end
```

### JSON Views

```elixir
# lib/my_app_web/views/user_view.ex
defmodule MyAppWeb.UserView do
  use MyAppWeb, :view

  def render("index.json", %{users: users}) do
    %{
      data: render_many(users, __MODULE__, "user.json"),
      meta: %{
        total: length(users)
      }
    }
  end

  def render("show.json", %{user: user}) do
    %{data: render_one(user, __MODULE__, "user.json")}
  end

  def render("user.json", %{user: user}) do
    %{
      id: user.id,
      name: user.name,
      email: user.email,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
```

### Error Handling

```elixir
# lib/my_app_web/controllers/fallback_controller.ex
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(MyAppWeb.ErrorView)
    |> render(:"404")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(MyAppWeb.ChangesetView)
    |> render("error.json", changeset: changeset)
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(MyAppWeb.ErrorView)
    |> render(:"401")
  end
end
```

---

## CI/CD Pipeline Management

### GitHub Actions Configuration

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]

env:
  MIX_ENV: test
  POSTGRES_PASSWORD: postgres

jobs:
  test:
    runs-on: ubuntu-20.04
    
    services:
      postgres:
        image: postgres:13
        env:
          POSTGRES_PASSWORD: ${{ env.POSTGRES_PASSWORD }}
          POSTGRES_DB: my_app_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432

    steps:
    - name: Checkout repository
      uses: actions/checkout@v3

    - name: Setup Elixir
      uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.14.4'
        otp-version: '25.0'

    - name: Cache dependencies
      uses: actions/cache@v3
      with:
        path: |
          deps
          _build
        key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
        restore-keys: ${{ runner.os }}-mix-

    - name: Install dependencies
      run: mix deps.get

    - name: Check formatting
      run: mix format --check-formatted

    - name: Run Credo
      run: mix credo --strict

    - name: Compile
      run: mix compile --warnings-as-errors

    - name: Run tests
      run: mix test --cover

    - name: Generate coverage report
      run: mix coveralls.github
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  deploy:
    needs: test
    runs-on: ubuntu-20.04
    if: github.ref == 'refs/heads/main'
    
    steps:
    - name: Deploy to production
      run: echo "Deploy to production server"
      # Add your deployment steps here
```

### Deployment Configuration

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Production

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-20.04
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v3

    - name: Setup Elixir
      uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.14.4'
        otp-version: '25.0'

    - name: Install dependencies
      run: mix deps.get --only prod

    - name: Compile release
      run: MIX_ENV=prod mix compile

    - name: Create release
      run: MIX_ENV=prod mix release

    - name: Deploy to server
      uses: appleboy/ssh-action@v0.1.5
      with:
        host: ${{ secrets.HOST }}
        username: ${{ secrets.USERNAME }}
        key: ${{ secrets.KEY }}
        script: |
          cd /path/to/your/app
          git pull origin main
          mix deps.get --only prod
          MIX_ENV=prod mix compile
          MIX_ENV=prod mix ecto.migrate
          MIX_ENV=prod mix release --overwrite
          sudo systemctl restart my_app
```

### Quality Gates

Create a comprehensive quality check script:

```bash
#!/bin/bash
# scripts/quality_check.sh

echo "🔍 Running code quality checks..."

echo "📋 Checking code formatting..."
mix format --check-formatted
if [ $? -ne 0 ]; then
    echo "❌ Code formatting check failed"
    exit 1
fi

echo "🕵️ Running Credo analysis..."
mix credo --strict
if [ $? -ne 0 ]; then
    echo "❌ Credo analysis failed"
    exit 1
fi

echo "🔬 Running Dialyzer..."
mix dialyzer
if [ $? -ne 0 ]; then
    echo "❌ Dialyzer analysis failed"
    exit 1
fi

echo "🧪 Running tests..."
mix test
if [ $? -ne 0 ]; then
    echo "❌ Tests failed"
    exit 1
fi

echo "📊 Generating coverage report..."
mix coveralls.html

echo "✅ All quality checks passed!"
```

---

## Essential Commands Reference

### Mix Commands

```bash
# Project management
mix new my_app                       # Create new project
mix new my_app --sup                 # With supervision tree
mix new my_app --umbrella           # Umbrella project
mix phx.new my_app                  # Create new Phoenix project
mix phx.new my_app --api            # API-only Phoenix app
mix phx.new my_app --live           # With Phoenix LiveView

# Dependencies and compilation
mix deps.get                        # Install dependencies
mix deps.get --only prod            # Install only production deps
mix deps.update --all               # Update all dependencies
mix deps.tree                       # Show dependency tree
mix deps.outdated                   # Check for outdated packages
mix compile                         # Compile project
mix compile --force                 # Force recompilation
mix clean                          # Clean compiled files

# Database operations
mix ecto.create                     # Create database
mix ecto.migrate                    # Run migrations
mix ecto.rollback                   # Rollback migration
mix ecto.rollback --step 3          # Rollback 3 migrations
mix ecto.reset                      # Drop, create, and migrate
mix ecto.setup                      # Create, migrate, and seed
mix ecto.gen.migration AddUsersTable # Generate migration

# Phoenix generators
mix phx.gen.html Accounts User users name:string email:string
mix phx.gen.json Blog Post posts title:string content:text
mix phx.gen.context Accounts User users name:string
mix phx.gen.live Blog Post posts title:string content:text
mix phx.gen.auth Accounts User users # Generate authentication
mix phx.gen.channel Room            # Generate channel

# Testing
mix test                            # Run all tests
mix test test/my_app/accounts_test.exs # Run specific test file
mix test --cover                    # Run tests with coverage
mix test --trace                    # Show test execution details
mix test --failed                   # Run only previously failed tests
mix coveralls.html                  # Generate HTML coverage report

# Code quality
mix format                          # Format code
mix format --check-formatted        # Check if code is formatted
mix credo                          # Run static analysis
mix credo --strict                 # Run strict analysis
mix dialyzer                       # Run type analysis
mix hex.audit                      # Check for security vulnerabilities

# Development and production
mix phx.server                      # Start Phoenix server
iex -S mix phx.server              # Start server with IEx console
mix release                        # Create production release
mix release --overwrite            # Overwrite existing release
MIX_ENV=prod mix compile           # Compile for production
MIX_ENV=prod mix phx.digest        # Digest static assets

# Environment-specific commands
MIX_ENV=test mix test              # Run tests in test environment
MIX_ENV=prod mix ecto.migrate     # Run migrations in production
MIX_ENV=dev mix phx.server         # Start development server
```

### Git Commands for Daily Workflow

```bash
# Daily workflow
git status                      # Check current status
git add .                       # Stage all changes
git commit -m "feat: add user authentication"  # Commit with message
git push origin feature-branch  # Push to remote branch

# Branch management
git branch                      # List local branches
git branch -r                   # List remote branches
git checkout -b new-feature     # Create and switch to new branch
git merge main                  # Merge main into current branch
git rebase main                 # Rebase current branch on main

# Useful shortcuts
git log --oneline              # Compact log view
git diff                       # Show unstaged changes
git diff --staged              # Show staged changes
git stash                      # Stash current changes
git stash pop                  # Apply and remove last stash
```

### Testing Commands

```bash
# Run specific tests
mix test test/my_app_web/controllers/user_controller_test.exs
mix test test/my_app_web/controllers/user_controller_test.exs:42

# Run tests with different options
mix test --trace               # Show test execution details
mix test --failed              # Run only previously failed tests
mix test --slowest 10          # Show 10 slowest tests
mix test --exclude integration # Exclude integration tests

# Coverage reports
mix test --cover               # Basic coverage
mix coveralls                  # Detailed coverage
mix coveralls.detail          # Line-by-line coverage
mix coveralls.html             # HTML coverage report
```

#### Testing Commands
```bash
# Basic testing
mix test                        # Run all tests
mix test test/my_app_web/controllers/user_controller_test.exs
mix test test/my_app_web/controllers/user_controller_test.exs:42

# Test options
mix test --trace               # Show test execution details
mix test --failed              # Run only previously failed tests
mix test --slowest 10          # Show 10 slowest tests
mix test --exclude integration # Exclude integration tests
mix test --only unit           # Run only unit tests
mix test --stale               # Run tests for changed files
mix test --listen-on-stdin     # Run tests on file change

# Coverage reports
mix test --cover               # Basic coverage
mix coveralls                  # Detailed coverage
mix coveralls.detail          # Line-by-line coverage
mix coveralls.html             # HTML coverage report
mix coveralls.json             # JSON coverage report

# Environment-specific testing
MIX_ENV=test mix test          # Explicitly set test environment
MIX_ENV=integration mix test   # Integration testing environment
```

### Development Best Practices Checklist

- ✅ Write tests before implementing features (TDD)
- ✅ Keep commits small and focused
- ✅ Use descriptive commit messages
- ✅ Run tests before pushing code
- ✅ Review your own code before requesting review
- ✅ Keep dependencies up to date
- ✅ Use proper error handling
- ✅ Document public API functions
- ✅ Follow Elixir naming conventions
- ✅ Keep functions small and focused

Remember: Good code is not just working code, but code that is maintainable, testable, and readable by your team members. Always prioritize clarity over cleverness!
