# Complete Product Development Guide: Best Practices & Junior Developer Training

## 🎯 **Product Development Best Practices**

### **1. Project Structure & Architecture**

#### **Monorepo Structure (Recommended for Full-Stack Teams)**
```
my-product/
├── apps/
│   ├── web-frontend/          # React/Next.js frontend
│   ├── mobile-app/            # React Native/Flutter
│   ├── backend-api/           # Elixir/Phoenix API
│   ├── admin-dashboard/       # Admin interface
│   └── worker-services/       # Background jobs
├── packages/
│   ├── shared-types/          # TypeScript types
│   ├── ui-components/         # Shared UI library
│   ├── utils/                 # Shared utilities
│   └── database-schemas/      # Database migrations
├── infrastructure/
│   ├── docker/               # Docker configurations
│   ├── kubernetes/           # K8s manifests
│   ├── terraform/            # Infrastructure as code
│   └── monitoring/           # Observability configs
├── docs/
│   ├── api/                  # API documentation
│   ├── architecture/         # System design docs
│   └── runbooks/            # Operational guides
└── tools/
    ├── scripts/             # Development scripts
    └── generators/          # Code generators
```

#### **Feature-Based Architecture**
```elixir
# Backend structure (Phoenix/Elixir)
lib/myapp/
├── accounts/               # User management
│   ├── user.ex
│   ├── auth.ex
│   └── schemas/
├── products/              # Product domain
│   ├── product.ex
│   ├── catalog.ex
│   └── inventory.ex
├── orders/                # Order processing
│   ├── order.ex
│   ├── payment.ex
│   └── fulfillment.ex
└── shared/               # Shared utilities
    ├── telemetry.ex
    └── storage.ex
```

### **2. Development Workflow**

#### **Git Flow Strategy**
```bash
# Main branches
main          # Production-ready code
develop       # Integration branch
release/*     # Release preparation
feature/*     # Feature development
hotfix/*      # Emergency fixes

# Example feature workflow
git checkout develop
git checkout -b feature/user-profile-enhancement
# ... work on feature ...
git push origin feature/user-profile-enhancement
# Create PR to develop
```

#### **Conventional Commits**
```bash
feat: add user profile photo upload
fix: resolve database connection timeout
docs: update API documentation for auth endpoints
style: format code according to style guide
refactor: extract user validation logic
test: add integration tests for payment flow
chore: update dependencies to latest versions
```

## 🏗️ **Codebase Maintenance Best Practices**

### **1. Code Quality Standards**

#### **Automated Code Quality Checks**
```yaml
# .github/workflows/code-quality.yml
name: Code Quality

on: [push, pull_request]

jobs:
  frontend-quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      # TypeScript/React checks
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'
      
      - run: npm ci
      - run: npm run type-check
      - run: npm run lint
      - run: npm run test:unit
      - run: npm run test:integration
      
      # Security audit
      - run: npm audit --audit-level moderate

  backend-quality:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
    
    steps:
      - uses: actions/checkout@v3
      
      # Elixir checks
      - name: Setup Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15'
          otp-version: '26'
      
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix credo --strict
      - run: mix dialyzer
      - run: mix test
      
      # Security checks
      - run: mix deps.audit
      - run: mix sobelow
```

#### **Pre-commit Hooks**
```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.4.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-json
      - id: check-yaml
  
  # Frontend hooks
  - repo: local
    hooks:
      - id: frontend-lint
        name: Frontend Lint
        entry: npm run lint
        language: node
        files: ^apps/web-frontend/
      
      - id: frontend-test
        name: Frontend Tests
        entry: npm run test:unit
        language: node
        files: ^apps/web-frontend/

  # Backend hooks
  - repo: local
    hooks:
      - id: elixir-format
        name: Elixir Format
        entry: mix format
        language: elixir
        files: \.exs?$
      
      - id: elixir-credo
        name: Elixir Credo
        entry: mix credo
        language: elixir
        files: \.exs?$
```

### **2. Documentation Strategy**

#### **Living Documentation**
```markdown
# docs/architecture/user-auth-flow.md

# User Authentication Flow

## Overview
This document describes the complete user authentication flow across our system.

## Sequence Diagram
```mermaid
sequenceDiagram
    participant U as User
    participant F as Frontend
    participant A as Auth Service
    participant D as Database
    
    U->>F: Login request
    F->>A: POST /auth/login
    A->>D: Validate credentials
    D-->>A: User data
    A-->>F: JWT token
    F-->>U: Redirect to dashboard
```

## API Endpoints
- `POST /auth/login` - User login
- `POST /auth/refresh` - Token refresh
- `DELETE /auth/logout` - User logout

## Security Considerations
- Tokens expire in 15 minutes
- Refresh tokens valid for 30 days
- Rate limiting: 5 attempts per minute
```

#### **API Documentation with OpenAPI**
```elixir
# lib/myapp_web/controllers/user_controller.ex
defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias MyApp.Accounts.User
  alias MyAppWeb.Schemas.UserResponse

  operation :show,
    summary: "Get user profile",
    parameters: [
      id: [in: :path, description: "User ID", type: :string, example: "123"]
    ],
    responses: [
      ok: {"User profile", "application/json", UserResponse},
      not_found: {"User not found", "application/json", ErrorResponse}
    ]

  def show(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      %User{} = user ->
        conn
        |> put_status(:ok)
        |> render("show.json", user: user)
      
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end
end
```

## 🚀 **CI/CD Pipeline Best Practices**

### **1. Multi-Stage Pipeline**

#### **Complete CI/CD Pipeline**
```yaml
# .github/workflows/deploy.yml
name: Deploy Pipeline

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  # Stage 1: Code Quality & Tests
  quality:
    runs-on: ubuntu-latest
    outputs:
      frontend-changed: ${{ steps.changes.outputs.frontend }}
      backend-changed: ${{ steps.changes.outputs.backend }}
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Detect changes
        uses: dorny/paths-filter@v2
        id: changes
        with:
          filters: |
            frontend:
              - 'apps/web-frontend/**'
            backend:
              - 'apps/backend-api/**'
      
      - name: Frontend Quality Checks
        if: steps.changes.outputs.frontend == 'true'
        run: |
          cd apps/web-frontend
          npm ci
          npm run lint
          npm run test:unit
          npm run build
      
      - name: Backend Quality Checks
        if: steps.changes.outputs.backend == 'true'
        run: |
          cd apps/backend-api
          mix deps.get
          mix test
          mix credo

  # Stage 2: Security Scanning
  security:
    needs: quality
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Run security scan
        uses: securecodewarrior/github-action-add-sarif@v1
        with:
          sarif-file: security-scan-results.sarif
      
      - name: Dependency vulnerability scan
        run: |
          # Frontend security audit
          cd apps/web-frontend && npm audit --audit-level high
          
          # Backend security audit  
          cd apps/backend-api && mix deps.audit

  # Stage 3: Build & Package
  build:
    needs: [quality, security]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/develop'
    
    strategy:
      matrix:
        service: [frontend, backend, worker]
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2
      
      - name: Login to Container Registry
        uses: docker/login-action@v2
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Build and push Docker image
        uses: docker/build-push-action@v4
        with:
          context: apps/${{ matrix.service }}
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}-${{ matrix.service }}:${{ github.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}-${{ matrix.service }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  # Stage 4: Deploy to Staging
  deploy-staging:
    needs: build
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/develop'
    environment: staging
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Deploy to Staging
        run: |
          # Update Kubernetes manifests
          sed -i 's|IMAGE_TAG|${{ github.sha }}|g' infrastructure/kubernetes/staging/*.yaml
          
          # Apply to staging cluster
          kubectl apply -f infrastructure/kubernetes/staging/
      
      - name: Run E2E Tests
        run: |
          # Wait for deployment
          kubectl rollout status deployment/myapp-frontend -n staging
          kubectl rollout status deployment/myapp-backend -n staging
          
          # Run end-to-end tests
          npm run test:e2e -- --baseUrl=https://staging.myapp.com
      
      - name: Performance Tests
        run: |
          # Load testing with k6
          k6 run --vus 50 --duration 2m tests/load/basic-flow.js

  # Stage 5: Deploy to Production
  deploy-production:
    needs: deploy-staging
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    environment: production
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Blue-Green Deployment
        run: |
          # Deploy to green environment
          kubectl apply -f infrastructure/kubernetes/production/green/
          
          # Wait for green to be ready
          kubectl rollout status deployment/myapp-backend-green -n production
          
          # Run smoke tests on green
          curl -f https://green.myapp.com/health
          
          # Switch traffic to green (blue-green swap)
          kubectl patch service myapp-backend -n production \
            -p '{"spec":{"selector":{"version":"green"}}}'
          
          # Scale down blue environment after 5 minutes
          sleep 300
          kubectl scale deployment myapp-backend-blue --replicas=0 -n production

  # Stage 6: Post-Deployment Monitoring
  monitor:
    needs: deploy-production
    runs-on: ubuntu-latest
    if: always()
    
    steps:
      - name: Send deployment notification
        uses: 8398a7/action-slack@v3
        with:
          status: ${{ job.status }}
          channel: '#deployments'
          webhook_url: ${{ secrets.SLACK_WEBHOOK }}
      
      - name: Update deployment metrics
        run: |
          # Record deployment metrics
          curl -X POST "https://api.datadog.com/api/v1/events" \
            -H "Content-Type: application/json" \
            -H "DD-API-KEY: ${{ secrets.DATADOG_API_KEY }}" \
            -d '{"title":"Production Deployment","text":"Deployed commit ${{ github.sha }}"}'
```

### **2. Environment Management**

#### **Environment-Specific Configurations**
```yaml
# infrastructure/kubernetes/staging/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-config
  namespace: staging
data:
  DATABASE_URL: "postgres://user:pass@staging-db:5432/myapp"
  REDIS_URL: "redis://staging-redis:6379"
  API_BASE_URL: "https://api.staging.myapp.com"
  LOG_LEVEL: "debug"
  ENABLE_DEBUG_TOOLS: "true"

---
# infrastructure/kubernetes/production/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-config
  namespace: production
data:
  DATABASE_URL: "postgres://user:pass@prod-db:5432/myapp"
  REDIS_URL: "redis://prod-redis:6379"
  API_BASE_URL: "https://api.myapp.com"
  LOG_LEVEL: "info"
  ENABLE_DEBUG_TOOLS: "false"
```

## 👨‍💻 **Training Junior Developers in "Vibe Coding"**

### **1. Rapid Feature Development Framework**

#### **Feature Development Workflow**
```markdown
# Feature Development Checklist for Junior Developers

## 🎯 **Phase 1: Understanding (30 minutes)**
- [ ] Read the feature requirements
- [ ] Understand the user story and acceptance criteria
- [ ] Identify affected components (frontend/backend)
- [ ] Ask clarifying questions in team chat

## 🏗️ **Phase 2: Planning (15 minutes)**
- [ ] Break down the feature into small tasks
- [ ] Identify database schema changes (if any)
- [ ] Plan the API endpoints needed
- [ ] Sketch the UI components

## ⚡ **Phase 3: Rapid Prototyping (2 hours)**
- [ ] Create feature branch: `feature/quick-prototype-[feature-name]`
- [ ] Build the simplest version that works
- [ ] Focus on functionality over perfection
- [ ] Use existing components and patterns

## 🧪 **Phase 4: Testing & Iteration (1 hour)**
- [ ] Test the happy path manually
- [ ] Share with team for quick feedback
- [ ] Iterate based on immediate feedback
- [ ] Write basic tests

## ✨ **Phase 5: Polish & Deploy (1 hour)**
- [ ] Refactor code for clarity
- [ ] Add proper error handling
- [ ] Write comprehensive tests
- [ ] Create pull request
```

#### **Vibe Coding Tools & Scripts**

```bash
#!/bin/bash
# tools/scripts/quick-feature.sh - Rapid feature scaffolding

FEATURE_NAME=$1
BRANCH_NAME="feature/vibe-${FEATURE_NAME}"

echo "🚀 Starting vibe coding session for: ${FEATURE_NAME}"

# Create feature branch
git checkout develop
git pull origin develop
git checkout -b $BRANCH_NAME

# Scaffold backend API
cd apps/backend-api
mix phx.gen.json $FEATURE_NAME ${FEATURE_NAME}s name:string description:text
mix ecto.migrate

# Scaffold frontend components
cd ../web-frontend
npx plop component $FEATURE_NAME

echo "✅ Feature scaffolded! Happy vibe coding!"
echo "📝 Next steps:"
echo "  1. Implement the API logic in lib/myapp/${FEATURE_NAME}s/"
echo "  2. Build the UI components in src/components/${FEATURE_NAME}/"
echo "  3. Test your changes with: npm run dev & mix phx.server"
```

#### **Component Generator (Plop.js)**
```javascript
// tools/plopfile.js
module.exports = function (plop) {
  // Component generator
  plop.setGenerator('component', {
    description: 'Create a new React component',
    prompts: [
      {
        type: 'input',
        name: 'name',
        message: 'Component name:'
      },
      {
        type: 'list',
        name: 'type',
        message: 'Component type:',
        choices: ['functional', 'class', 'page']
      }
    ],
    actions: [
      {
        type: 'add',
        path: 'apps/web-frontend/src/components/{{pascalCase name}}/index.tsx',
        templateFile: 'tools/templates/component.hbs'
      },
      {
        type: 'add',
        path: 'apps/web-frontend/src/components/{{pascalCase name}}/{{pascalCase name}}.test.tsx',
        templateFile: 'tools/templates/component.test.hbs'
      },
      {
        type: 'add',
        path: 'apps/web-frontend/src/components/{{pascalCase name}}/{{pascalCase name}}.stories.tsx',
        templateFile: 'tools/templates/component.stories.hbs'
      }
    ]
  });

  // API endpoint generator
  plop.setGenerator('api', {
    description: 'Create a new API endpoint',
    prompts: [
      {
        type: 'input',
        name: 'resource',
        message: 'Resource name (singular):'
      },
      {
        type: 'checkbox',
        name: 'actions',
        message: 'Select actions:',
        choices: ['index', 'show', 'create', 'update', 'delete']
      }
    ],
    actions: [
      {
        type: 'add',
        path: 'apps/backend-api/lib/myapp_web/controllers/{{snake_case resource}}_controller.ex',
        templateFile: 'tools/templates/controller.hbs'
      },
      {
        type: 'add',
        path: 'apps/backend-api/test/myapp_web/controllers/{{snake_case resource}}_controller_test.exs',
        templateFile: 'tools/templates/controller.test.hbs'
      }
    ]
  });
};
```

### **2. Junior Developer Training Program**

#### **Week 1-2: Foundation**
```markdown
# Junior Developer Onboarding - Weeks 1-2

## Goals
- Understand the codebase structure
- Set up development environment
- Complete first simple feature

## Daily Tasks

### Day 1-3: Environment Setup
- [ ] Clone repository and run setup scripts
- [ ] Install all development tools
- [ ] Run the application locally
- [ ] Complete "Hello World" commit

### Day 4-7: Codebase Exploration
- [ ] Read architecture documentation
- [ ] Follow a request from frontend to backend
- [ ] Understand database schema
- [ ] Complete code reading exercises

### Day 8-10: First Feature
- [ ] Pick a small bug fix from the backlog
- [ ] Follow the vibe coding process
- [ ] Submit first pull request
- [ ] Address code review feedback

## Success Metrics
- Can run application locally without help
- Understands basic request flow
- Completes first PR with minimal guidance
```

#### **Code Review Guidelines for Mentors**
```markdown
# Code Review Guidelines for Junior Developers

## What to Focus On (Priority Order)

### 1. Functionality (Must Fix)
- [ ] Does the code work as intended?
- [ ] Are edge cases handled?
- [ ] Are there any obvious bugs?

### 2. Security (Must Fix)
- [ ] No hardcoded secrets
- [ ] Proper input validation
- [ ] SQL injection prevention
- [ ] XSS prevention

### 3. Performance (Should Fix)
- [ ] No N+1 queries
- [ ] Appropriate caching
- [ ] Efficient algorithms
- [ ] Database indexes

### 4. Code Quality (Nice to Fix)
- [ ] Clear variable names
- [ ] Proper function decomposition
- [ ] Consistent formatting
- [ ] Good comments

## How to Give Feedback

### ✅ Good Examples
```
// Good: Specific and educational
"Consider using a Map here instead of Object.keys() for O(1) lookup instead of O(n)"

// Good: Suggests improvement with example
"This function is doing multiple things. Consider splitting it:
```javascript
const validateUser = (user) => { ... }
const saveUser = (user) => { ... }
```

### ❌ Bad Examples
```
// Bad: Too vague
"This code is not good"

// Bad: Not educational
"Fix this"
```

### **3. Pair Programming Sessions**

#### **Structured Pair Programming**
```markdown
# Pair Programming Session Template

## Pre-Session (5 minutes)
- [ ] Define the goal for this session
- [ ] Set up screen sharing
- [ ] Decide who drives first (switch every 30 minutes)

## Session Structure (90 minutes)
- [ ] 30 min: Driver 1 codes, Navigator 1 guides
- [ ] 5 min: Quick retrospective and role switch
- [ ] 30 min: Driver 2 codes, Navigator 2 guides  
- [ ] 5 min: Quick retrospective and role switch
- [ ] 30 min: Driver 1 codes, Navigator 1 guides
- [ ] 10 min: Session wrap-up and documentation

## Focus Areas by Session
- **Session 1-3**: Basic CRUD operations
- **Session 4-6**: Error handling and validation
- **Session 7-9**: Testing and debugging
- **Session 10-12**: Performance optimization
```

## 🔄 **Continuous Improvement Process**

### **1. Metrics & Monitoring**

#### **Development Metrics Dashboard**
```elixir
# lib/myapp/metrics/development_metrics.ex
defmodule MyApp.Metrics.DevelopmentMetrics do
  use GenServer
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def track_deployment(environment, duration, success) do
    GenServer.cast(__MODULE__, {:track_deployment, environment, duration, success})
  end

  def track_feature_completion(developer, feature_size, duration) do
    GenServer.cast(__MODULE__, {:track_feature, developer, feature_size, duration})
  end

  # Generate weekly development report
  def generate_weekly_report do
    metrics = GenServer.call(__MODULE__, :get_metrics)
    
    %{
      deployment_success_rate: calculate_success_rate(metrics.deployments),
      average_feature_time: calculate_avg_time(metrics.features),
      developer_velocity: calculate_velocity(metrics.features),
      technical_debt: estimate_tech_debt(metrics.code_quality)
    }
  end
end
```

### **2. Retrospective Process**

#### **Weekly Team Retrospective Template**
```markdown
# Weekly Retrospective - [Date]

## 🎯 What Went Well (Keep Doing)
- Deployments were smooth this week
- Junior developer completed 3 features independently
- Code review turnaround time improved to < 4 hours

## 🚧 What Could Be Improved (Start Doing)
- Need better error monitoring in production
- API documentation is falling behind
- More automated testing for edge cases

## 🛑 What Didn't Work (Stop Doing)
- Manual deployment process is too slow
- Long-running feature branches cause merge conflicts
- Insufficient communication about breaking changes

## 📋 Action Items for Next Week
- [ ] Set up automated error monitoring (Owner: Senior Dev)
- [ ] Create API documentation automation (Owner: Junior Dev)
- [ ] Implement feature flags for gradual rollouts (Owner: Team)

## 📊 Metrics This Week
- Deployment frequency: 12 (target: 10+)
- Lead time: 2.3 days (target: < 3 days)
- Mean time to recovery: 15 minutes (target: < 30 min)
- Change failure rate: 5% (target: < 10%)
```

### **3. Learning & Development**

#### **Skill Development Roadmap**
```markdown
# Junior Developer Skill Development Roadmap

## Month 1: Foundation
- [ ] Git workflow mastery
- [ ] Basic debugging techniques
- [ ] Understanding the codebase architecture
- [ ] Writing clean, readable code

## Month 2: Feature Development
- [ ] Full-stack feature implementation
- [ ] Writing comprehensive tests
- [ ] Database design principles
- [ ] API design best practices

## Month 3: Quality & Performance
- [ ] Code review skills
- [ ] Performance optimization
- [ ] Security awareness
- [ ] Monitoring and logging

## Month 4: Collaboration & Leadership
- [ ] Mentoring newer developers
- [ ] Leading small features
- [ ] Technical documentation
- [ ] Process improvement suggestions

## Ongoing Learning Resources
- Weekly tech talks (Fridays 4-5 PM)
- Monthly architecture deep-dives
- Quarterly external conference attendance
- Book club: Technical and leadership books
```

## 🎓 **Training Exercises for Junior Developers**

### **Exercise 1: API Integration Challenge**
```markdown
# Challenge: Build a Weather Dashboard

## Requirements (2-day sprint)
1. Create an API endpoint that fetches weather data from external service
2. Build a React component that displays current weather
3. Add error handling for API failures
4. Write tests for both frontend and backend
5. Deploy to staging environment

## Learning Objectives
- API integration patterns
- Error handling strategies
- Testing methodologies
- Deployment process

## Success Criteria
- [ ] API returns weather data in consistent format
- [ ] UI handles loading and error states gracefully
- [ ] Tests achieve >80% coverage
- [ ] Successfully deployed and accessible
```

### **Exercise 2: Performance Optimization**
```markdown
# Challenge: Optimize Slow Page Load

## Scenario
The user dashboard is loading slowly (>3 seconds). Your task is to:

1. Identify performance bottlenecks
2. Implement optimizations
3. Measure improvements
4. Document your findings

## Tools Provided
- Chrome DevTools
- Database query analyzer
- Performance monitoring dashboard

## Learning Objectives
- Performance debugging techniques
- Database query optimization
- Frontend performance patterns
- Monitoring and measurement
```

## 🔧 **Development Tools & Setup**

### **Development Environment Setup Script**
```bash
#!/bin/bash
# tools/scripts/dev-setup.sh

set -e

echo "🚀 Setting up development environment..."

# Install system dependencies
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS setup
    brew install elixir nodejs postgresql redis
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Ubuntu/Debian setup
    sudo apt-get update
    sudo apt-get install -y elixir nodejs npm postgresql redis-server
fi

# Install global tools
npm install -g @angular/cli create-react-app
mix local.hex --force
mix local.rebar --force

# Clone and setup project
git clone https://github.com/yourorg/your-product.git
cd your-product

# Backend setup
cd apps/backend-api
mix deps.get
mix ecto.setup

# Frontend setup
cd ../web-frontend
npm install
npm run build

# Verify setup
echo "🧪 Running verification tests..."
cd ../../
npm run test:verify

echo "✅ Development environment setup complete!"
echo "🎯 Next steps:"
echo "  1. Run 'npm run dev' to start all services"
echo "  2. Open http://localhost:3000 in your browser"
echo "  3. Check out the getting started guide: docs/getting-started.md"
```

### **Local Development Docker Compose**
```yaml
# docker-compose.local.yml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: myapp_dev
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  mailhog:
    image: mailhog/mailhog
    ports:
      - "1025:1025"  # SMTP
      - "8025:8025"  # Web UI

  minio:
    image: minio/minio
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - minio_data:/data

volumes:
  postgres_data:
  minio_data:
```

## 📊 **Monitoring & Observability**

### **Application Health Monitoring**
```elixir
# lib/myapp_web/controllers/health_controller.ex
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller
  
  def check(conn, _params) do
    health = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      version: Application.spec(:myapp, :vsn),
      uptime: System.uptime(),
      checks: %{
        database: check_database(),
        redis: check_redis(),
        external_api: check_external_services()
      }
    }
    
    overall_status = if all_healthy?(health.checks), do: 200, else: 503
    
    conn
    |> put_status(overall_status)
    |> json(health)
  end
  
  defp check_database do
    case Ecto.Adapters.SQL.query(MyApp.Repo, "SELECT 1", []) do
      {:ok, _} -> "healthy"
      {:error, _} -> "unhealthy"
    end
  end
  
  defp check_redis do
    case Redix.command(:redix, ["PING"]) do
      {:ok, "PONG"} -> "healthy"
      {:error, _} -> "unhealthy"
    end
  end
  
  defp check_external_services do
    # Check critical external API dependencies
    case HTTPoison.get("https://api.external-service.com/health", [], recv_timeout: 5000) do
      {:ok, %HTTPoison.Response{status_code: 200}} -> "healthy"
      _ -> "degraded"
    end
  end
  
  defp all_healthy?(checks) do
    Enum.all?(checks, fn {_service, status} -> status == "healthy" end)
  end
end
```

### **Structured Logging**
```elixir
# lib/myapp/application.ex
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    # Configure structured logging
    Logger.configure(level: :info)
    Logger.configure_backend(:console, format: {MyApp.LogFormatter, :format})
    
    children = [
      MyApp.Repo,
      MyAppWeb.Telemetry,
      MyAppWeb.Endpoint,
      # Add telemetry supervisor
      {TelemetryMetricsPrometheus, metrics: MyApp.Telemetry.metrics()}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule MyApp.LogFormatter do
  def format(level, message, timestamp, metadata) do
    %{
      timestamp: timestamp,
      level: level,
      message: message,
      metadata: metadata,
      service: "myapp-backend",
      version: Application.spec(:myapp, :vsn)
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end
end
```

This comprehensive guide provides a complete framework for:
- **Product development best practices** with modern tooling
- **Robust CI/CD pipelines** for reliable deployments
- **Codebase maintenance** strategies for long-term sustainability
- **Junior developer training** in rapid, iterative "vibe coding"
- **Monitoring and observability** for production systems

The approach emphasizes rapid iteration while maintaining professional standards, automated quality gates, and continuous learning for both junior and senior developers.

[View your comprehensive guide](computer:///mnt/user-data/outputs/complete-product-development-guide.md)
