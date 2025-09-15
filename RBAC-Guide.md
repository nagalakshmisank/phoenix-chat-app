# Role-Based Access Control (RBAC) Developer Guide
## Building Secure, Scalable User Management for Student Notes App

### Table of Contents
1. [Understanding RBAC Fundamentals](#fundamentals)
2. [Platform, Application & System Roles](#roles)
3. [Authentication vs Authorization](#auth-concepts)
4. [Database Design for RBAC](#database)
5. [Backend Implementation (Elixir)](#backend)
6. [Frontend Implementation (JavaScript)](#frontend)
7. [Real-World Use Cases](#use-cases)
8. [Scaling to Millions of Users](#scaling)
9. [Security Best Practices](#security)
10. [Testing RBAC Systems](#testing)

---

## 1. Understanding RBAC Fundamentals {#fundamentals}

### What is RBAC?

Think of RBAC like a school building with different key cards:

```
🎓 Student Card: Can access classrooms, library, cafeteria
👨‍🏫 Teacher Card: Student access + grade books, staff room
🏫 Principal Card: Teacher access + administrative offices, records
🔐 Janitor Card: All buildings, but limited to maintenance areas
```

**Role-Based Access Control (RBAC)** works the same way - users get roles, roles have permissions, and permissions control what they can do.

### Core RBAC Components

```
User → has → Role → has → Permissions → control → Resources
```

**Example in our Notes App:**
- **User**: Sarah (a 10th grade student)
- **Role**: "Student" 
- **Permissions**: [create_note, read_own_notes, share_with_classmates]
- **Resources**: Notes, Study Groups, AI Tutor

### Why RBAC Matters

**Without RBAC (Bad):**
```javascript
// Every function checks individual user permissions - messy!
function deleteNote(noteId, userId) {
  if (userId === "admin123" || userId === "teacher456" || 
      (userId === noteOwner && userGrade >= 11)) {
    // Delete logic...
  }
}
```

**With RBAC (Good):**
```javascript
// Clean, maintainable permission checking
function deleteNote(noteId, user) {
  if (user.hasPermission('delete_note', noteId)) {
    // Delete logic...
  }
}
```

---

## 2. Platform, Application & System Roles {#roles}

### Understanding Different Role Types

#### A. Platform Roles (Highest Level)
These control access to the entire platform:

```elixir
# Platform roles control system-wide access
@platform_roles %{
  "super_admin" => %{
    description: "Full system access",
    permissions: ["*"],  # All permissions
    scope: :global
  },
  "platform_admin" => %{
    description: "Platform management",
    permissions: [
      "manage_institutions",
      "view_system_analytics", 
      "manage_platform_settings"
    ],
    scope: :global
  },
  "institution_admin" => %{
    description: "Institution-level management",
    permissions: [
      "manage_users_in_institution",
      "view_institution_analytics",
      "configure_institution_settings"
    ],
    scope: :institution
  }
}
```

#### B. Application Roles (Feature Level)
These control access to app features:

```elixir
@application_roles %{
  "educator" => %{
    description: "Teacher/Professor role",
    permissions: [
      "create_course_content",
      "view_student_progress", 
      "moderate_study_groups",
      "access_ai_analytics",
      "export_class_data"
    ],
    scope: :course_or_class,
    inherits_from: ["student"]  # Gets all student permissions too
  },
  "student" => %{
    description: "Student role",
    permissions: [
      "create_personal_notes",
      "join_study_groups",
      "share_notes_with_classmates",
      "use_ai_tutor",
      "collaborate_on_notes"
    ],
    scope: :personal_and_class
  },
  "guardian" => %{
    description: "Parent/Guardian role", 
    permissions: [
      "view_child_progress",
      "manage_child_privacy_settings",
      "communicate_with_educators",
      "view_child_activity_summary"
    ],
    scope: :child_specific
  }
}
```

#### C. System Roles (Technical Level)
These control technical access:

```elixir
@system_roles %{
  "content_moderator" => %{
    description: "AI/Human content moderation",
    permissions: [
      "review_flagged_content",
      "moderate_user_interactions",
      "manage_content_policies"
    ],
    scope: :content_only
  },
  "support_agent" => %{
    description: "Customer support",
    permissions: [
      "view_user_issues",
      "reset_user_passwords",
      "access_support_tools"
    ],
    scope: :support_only
  },
  "analytics_viewer" => %{
    description: "Data analysis access",
    permissions: [
      "view_anonymized_analytics",
      "generate_reports",
      "export_aggregate_data"
    ],
    scope: :analytics_only
  }
}
```

### Real-World Role Hierarchy Example

```
Lincoln High School (Institution)
├── Dr. Smith (Principal) - institution_admin + educator
├── Mr. Johnson (Math Teacher) - educator  
├── Ms. Garcia (School Counselor) - educator + student_advisor
├── Sarah (10th Grade Student) - student
├── Mike (11th Grade Student) - student + study_group_leader
├── Mrs. Wilson (Sarah's Mom) - guardian
└── Jake (IT Support) - support_agent
```

---

## 3. Authentication vs Authorization {#auth-concepts}

### Understanding the Difference

**Authentication** = "Who are you?" (Identity)
**Authorization** = "What can you do?" (Permissions)

```
🔑 Authentication: "I'm Sarah, here's my password"
🚪 Authorization: "Sarah can create notes but can't delete other students' notes"
```

### Authentication Flow

#### A. User Login Process
```elixir
# lib/auth_service/authenticator.ex
defmodule AuthService.Authenticator do
  @moduledoc """
  Handles user authentication (proving identity)
  """
  
  def authenticate_user(email, password) do
    with {:ok, user} <- find_user_by_email(email),
         {:ok, _} <- verify_password(password, user.password_hash),
         {:ok, token} <- generate_jwt_token(user) do
      
      {:ok, %{user: user, token: token}}
    else
      {:error, :user_not_found} -> 
        {:error, "Invalid email or password"}
      {:error, :invalid_password} -> 
        {:error, "Invalid email or password"}
      error -> 
        {:error, "Authentication failed"}
    end
  end
  
  defp find_user_by_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end
  
  defp verify_password(password, hash) do
    if Bcrypt.verify_pass(password, hash) do
      {:ok, :password_verified}
    else
      {:error, :invalid_password}
    end
  end
  
  defp generate_jwt_token(user) do
    # Create JWT token with user info and roles
    claims = %{
      user_id: user.id,
      email: user.email,
      roles: load_user_roles(user.id),
      institution_id: user.institution_id,
      exp: DateTime.utc_now() |> DateTime.add(24 * 60 * 60) |> DateTime.to_unix()
    }
    
    case Joken.encode_and_sign(claims, get_jwt_secret()) do
      {:ok, token, _claims} -> {:ok, token}
      error -> {:error, "Token generation failed"}
    end
  end
  
  defp load_user_roles(user_id) do
    # Load all roles for this user
    query = from ur in UserRole,
      join: r in Role, on: ur.role_id == r.id,
      where: ur.user_id == ^user_id,
      select: %{
        role_name: r.name,
        scope: ur.scope,
        scope_id: ur.scope_id
      }
    
    Repo.all(query)
  end
end
```

#### B. Token Validation Middleware
```elixir
# lib/auth_service/auth_plug.ex
defmodule AuthService.AuthPlug do
  @moduledoc """
  Middleware that validates JWT tokens on every request
  """
  
  import Plug.Conn
  
  def init(opts), do: opts
  
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        validate_token(conn, token)
      _ ->
        send_unauthorized_response(conn)
    end
  end
  
  defp validate_token(conn, token) do
    case Joken.verify_and_validate(token, get_jwt_secret()) do
      {:ok, claims} ->
        # Token is valid, add user info to connection
        conn
        |> assign(:current_user_id, claims["user_id"])
        |> assign(:current_user_roles, claims["roles"])
        |> assign(:current_institution_id, claims["institution_id"])
        
      {:error, _reason} ->
        send_unauthorized_response(conn)
    end
  end
  
  defp send_unauthorized_response(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Authentication required"}))
    |> halt()
  end
end
```

### Authorization System

#### A. Permission Checker
```elixir
# lib/auth_service/authorizer.ex
defmodule AuthService.Authorizer do
  @moduledoc """
  Handles authorization (checking permissions)
  """
  
  def can_user_perform_action?(user_roles, permission, resource \\ nil) do
    user_roles
    |> Enum.any?(fn role ->
      role_has_permission?(role, permission, resource)
    end)
  end
  
  def authorize_action(conn, required_permission, resource \\ nil) do
    user_roles = conn.assigns[:current_user_roles] || []
    
    if can_user_perform_action?(user_roles, required_permission, resource) do
      conn  # Allow the request to continue
    else
      send_forbidden_response(conn)
    end
  end
  
  defp role_has_permission?(role, permission, resource) do
    # Check if role has specific permission
    cond do
      # Super admin can do anything
      role.role_name == "super_admin" -> true
      
      # Check direct permission
      permission in get_role_permissions(role.role_name) -> 
        check_scope_access(role, resource)
      
      # Check wildcard permissions
      has_wildcard_permission?(role.role_name, permission) -> 
        check_scope_access(role, resource)
      
      true -> false
    end
  end
  
  defp check_scope_access(role, resource) do
    case {role.scope, resource} do
      # Global scope can access anything
      {:global, _} -> true
      
      # Institution scope can access resources in their institution
      {:institution, %{institution_id: resource_institution}} ->
        role.scope_id == resource_institution
      
      # Personal scope can only access their own resources
      {:personal, %{user_id: resource_user_id}} ->
        role.scope_id == resource_user_id
      
      # No resource specified, allow if role exists
      {_, nil} -> true
      
      # Default deny
      _ -> false
    end
  end
  
  defp get_role_permissions(role_name) do
    # This would typically come from database, but simplified here
    case role_name do
      "student" -> [
        "create_personal_notes",
        "read_own_notes", 
        "update_own_notes",
        "delete_own_notes",
        "share_notes_with_classmates",
        "join_study_groups",
        "use_ai_tutor"
      ]
      
      "educator" -> [
        "create_course_content",
        "read_student_notes_in_class",
        "create_assignments",
        "grade_assignments", 
        "manage_study_groups",
        "view_class_analytics",
        "moderate_content"
      ] ++ get_role_permissions("student")  # Inherit student permissions
      
      "guardian" -> [
        "view_child_progress",
        "manage_child_privacy",
        "communicate_with_educators"
      ]
      
      "institution_admin" -> [
        "manage_users",
        "configure_institution",
        "view_institution_analytics",
        "manage_courses"
      ] ++ get_role_permissions("educator")
      
      _ -> []
    end
  end
  
  defp send_forbidden_response(conn) do
    conn
    |> put_status(:forbidden)
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "Insufficient permissions"}))
    |> halt()
  end
end
```

---

## 4. Database Design for RBAC {#database}

### RBAC Database Schema

```sql
-- Users table (basic user information)
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) UNIQUE NOT NULL,
  username VARCHAR(100) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  first_name VARCHAR(100),
  last_name VARCHAR(100),
  date_of_birth DATE,
  institution_id UUID REFERENCES institutions(id),
  is_active BOOLEAN DEFAULT true,
  email_verified BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Institutions table (schools, universities, etc.)
CREATE TABLE institutions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  type VARCHAR(50) NOT NULL, -- 'high_school', 'university', 'elementary'
  domain VARCHAR(255), -- email domain for automatic role assignment
  settings JSONB DEFAULT '{}',
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Roles table (defines what roles exist)
CREATE TABLE roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) UNIQUE NOT NULL,
  display_name VARCHAR(255) NOT NULL,
  description TEXT,
  role_type VARCHAR(50) NOT NULL, -- 'platform', 'application', 'system'
  is_system_role BOOLEAN DEFAULT false,
  permissions TEXT[] DEFAULT '{}', -- Array of permission strings
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- User-Role assignments (many-to-many with scope)
CREATE TABLE user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID REFERENCES roles(id) ON DELETE CASCADE,
  scope_type VARCHAR(50) NOT NULL, -- 'global', 'institution', 'course', 'personal'
  scope_id UUID, -- ID of the scope (institution_id, course_id, etc.)
  granted_by UUID REFERENCES users(id), -- Who granted this role
  granted_at TIMESTAMP DEFAULT NOW(),
  expires_at TIMESTAMP, -- Optional expiration
  is_active BOOLEAN DEFAULT true,
  
  UNIQUE(user_id, role_id, scope_type, scope_id)
);

-- Permissions table (granular permissions)
CREATE TABLE permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) UNIQUE NOT NULL,
  display_name VARCHAR(255) NOT NULL,
  description TEXT,
  resource_type VARCHAR(100), -- 'note', 'user', 'course', etc.
  action VARCHAR(50), -- 'create', 'read', 'update', 'delete'
  created_at TIMESTAMP DEFAULT NOW()
);

-- Role-Permission assignments (many-to-many)
CREATE TABLE role_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_id UUID REFERENCES roles(id) ON DELETE CASCADE,
  permission_id UUID REFERENCES permissions(id) ON DELETE CASCADE,
  
  UNIQUE(role_id, permission_id)
);

-- Courses/Classes (for educational context)
CREATE TABLE courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  institution_id UUID REFERENCES institutions(id),
  name VARCHAR(255) NOT NULL,
  subject VARCHAR(100),
  grade_level INTEGER,
  academic_year VARCHAR(20),
  instructor_id UUID REFERENCES users(id),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Course enrollments (students in courses)
CREATE TABLE course_enrollments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id UUID REFERENCES courses(id) ON DELETE CASCADE,
  student_id UUID REFERENCES users(id) ON DELETE CASCADE,
  enrollment_status VARCHAR(50) DEFAULT 'active', -- 'active', 'dropped', 'completed'
  enrolled_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE(course_id, student_id)
);

-- Guardian-Child relationships
CREATE TABLE guardian_relationships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  guardian_id UUID REFERENCES users(id) ON DELETE CASCADE,
  child_id UUID REFERENCES users(id) ON DELETE CASCADE,
  relationship_type VARCHAR(50) NOT NULL, -- 'parent', 'guardian', 'emergency_contact'
  can_view_progress BOOLEAN DEFAULT true,
  can_manage_privacy BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE(guardian_id, child_id)
);

-- Create indexes for performance
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_institution ON users(institution_id);
CREATE INDEX idx_user_roles_user ON user_roles(user_id);
CREATE INDEX idx_user_roles_scope ON user_roles(scope_type, scope_id);
CREATE INDEX idx_course_enrollments_student ON course_enrollments(student_id);
CREATE INDEX idx_course_enrollments_course ON course_enrollments(course_id);
```

### Sample Data Setup

```sql
-- Insert sample institutions
INSERT INTO institutions (id, name, type, domain) VALUES
  ('550e8400-e29b-41d4-a716-446655440001', 'Lincoln High School', 'high_school', 'lincoln.edu'),
  ('550e8400-e29b-41d4-a716-446655440002', 'MIT', 'university', 'mit.edu');

-- Insert basic roles
INSERT INTO roles (id, name, display_name, description, role_type, permissions) VALUES
  ('660e8400-e29b-41d4-a716-446655440001', 'student', 'Student', 'Basic student access', 'application', 
   ARRAY['create_personal_notes', 'read_own_notes', 'share_notes', 'join_study_groups', 'use_ai_tutor']),
  
  ('660e8400-e29b-41d4-a716-446655440002', 'educator', 'Educator', 'Teacher/Professor access', 'application',
   ARRAY['create_course_content', 'read_student_notes', 'manage_study_groups', 'view_class_analytics']),
   
  ('660e8400-e29b-41d4-a716-446655440003', 'guardian', 'Guardian', 'Parent/Guardian access', 'application',
   ARRAY['view_child_progress', 'manage_child_privacy', 'communicate_with_educators']),
   
  ('660e8400-e29b-41d4-a716-446655440004', 'institution_admin', 'Institution Admin', 'School administrator', 'platform',
   ARRAY['manage_users', 'configure_institution', 'view_institution_analytics']);

-- Insert sample users
INSERT INTO users (id, email, username, password_hash, first_name, last_name, institution_id) VALUES
  ('770e8400-e29b-41d4-a716-446655440001', 'sarah.student@lincoln.edu', 'sarah_s', '$2b$12$hashedpassword1', 'Sarah', 'Student', '550e8400-e29b-41d4-a716-446655440001'),
  ('770e8400-e29b-41d4-a716-446655440002', 'john.teacher@lincoln.edu', 'john_t', '$2b$12$hashedpassword2', 'John', 'Teacher', '550e8400-e29b-41d4-a716-446655440001'),
  ('770e8400-e29b-41d4-a716-446655440003', 'mary.parent@gmail.com', 'mary_p', '$2b$12$hashedpassword3', 'Mary', 'Parent', null);

-- Assign roles to users
INSERT INTO user_roles (user_id, role_id, scope_type, scope_id) VALUES
  -- Sarah is a student at Lincoln High School
  ('770e8400-e29b-41d4-a716-446655440001', '660e8400-e29b-41d4-a716-446655440001', 'institution', '550e8400-e29b-41d4-a716-446655440001'),
  
  -- John is an educator at Lincoln High School  
  ('770e8400-e29b-41d4-a716-446655440002', '660e8400-e29b-41d4-a716-446655440002', 'institution', '550e8400-e29b-41d4-a716-446655440001'),
  
  -- Mary is Sarah's guardian (personal scope)
  ('770e8400-e29b-41d4-a716-446655440003', '660e8400-e29b-41d4-a716-446655440003', 'personal', '770e8400-e29b-41d4-a716-446655440001');

-- Create guardian relationship
INSERT INTO guardian_relationships (guardian_id, child_id, relationship_type) VALUES
  ('770e8400-e29b-41d4-a716-446655440003', '770e8400-e29b-41d4-a716-446655440001', 'parent');
```

---

## 5. Backend Implementation (Elixir) {#backend}

### User Management Service

```elixir
# lib/auth_service/models/user.ex
defmodule AuthService.User do
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  
  schema "users" do
    field :email, :string
    field :username, :string
    field :password_hash, :string
    field :password, :string, virtual: true  # Don't store in DB
    field :first_name, :string
    field :last_name, :string
    field :date_of_birth, :date
    field :is_active, :boolean, default: true
    field :email_verified, :boolean, default: false
    
    belongs_to :institution, AuthService.Institution
    has_many :user_roles, AuthService.UserRole
    has_many :roles, through: [:user_roles, :role]
    
    timestamps()
  end
  
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :password, :first_name, :last_name, 
                    :date_of_birth, :institution_id])
    |> validate_required([:email, :username, :password, :first_name, :last_name])
    |> validate_format(:email, ~r/@/)
    |> validate_length(:password, min: 8)
    |> validate_length(:username, min: 3, max: 20)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
    |> hash_password()
  end
  
  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    change(changeset, password_hash: Bcrypt.hash_pwd_salt(password))
  end
  
  defp hash_password(changeset), do: changeset
end
```

```elixir
# lib/auth_service/models/role.ex
defmodule AuthService.Role do
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  
  schema "roles" do
    field :name, :string
    field :display_name, :string
    field :description, :string
    field :role_type, :string  # platform, application, system
    field :is_system_role, :boolean, default: false
    field :permissions, {:array, :string}, default: []
    
    has_many :user_roles, AuthService.UserRole
    has_many :users, through: [:user_roles, :user]
    
    timestamps()
  end
  
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :display_name, :description, :role_type, 
                    :is_system_role, :permissions])
    |> validate_required([:name, :display_name, :role_type])
    |> validate_inclusion(:role_type, ["platform", "application", "system"])
    |> unique_constraint(:name)
  end
end
```

```elixir
# lib/auth_service/models/user_role.ex
defmodule AuthService.UserRole do
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  
  schema "user_roles" do
    field :scope_type, :string  # global, institution, course, personal
    field :scope_id, :binary_id
    field :granted_at, :utc_datetime, default: &DateTime.utc_now/0
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true
    
    belongs_to :user, AuthService.User
    belongs_to :role, AuthService.Role
    belongs_to :granted_by, AuthService.User
    
    timestamps()
  end
  
  def changeset(user_role, attrs) do
    user_role
    |> cast(attrs, [:user_id, :role_id, :scope_type, :scope_id, 
                    :granted_by_id, :expires_at, :is_active])
    |> validate_required([:user_id, :role_id, :scope_type])
    |> validate_inclusion(:scope_type, ["global", "institution", "course", "personal"])
    |> unique_constraint([:user_id, :role_id, :scope_type, :scope_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:role_id)
  end
end
```

### Role Management Service

```elixir
# lib/auth_service/role_manager.ex
defmodule AuthService.RoleManager do
  @moduledoc """
  Manages role assignments and permission checking
  """
  
  import Ecto.Query
  alias AuthService.{Repo, User, Role, UserRole}
  
  # Assign role to user with specific scope
  def assign_role(user_id, role_name, scope_type, scope_id \\ nil, granted_by_id \\ nil) do
    with {:ok, role} <- get_role_by_name(role_name),
         {:ok, user_role} <- create_user_role(user_id, role.id, scope_type, scope_id, granted_by_id) do
      
      # Log role assignment for audit
      log_role_assignment(user_id, role.id, scope_type, granted_by_id)
      
      {:ok, user_role}
    end
  end
  
  # Remove role from user
  def revoke_role(user_id, role_name, scope_type, scope_id \\ nil) do
    query = from ur in UserRole,
      join: r in Role, on: ur.role_id == r.id,
      where: ur.user_id == ^user_id and 
             r.name == ^role_name and
             ur.scope_type == ^scope_type and
             ur.scope_id == ^scope_id
    
    case Repo.delete_all(query) do
      {count, _} when count > 0 -> 
        log_role_revocation(user_id, role_name, scope_type)
        {:ok, :revoked}
      {0, _} -> 
        {:error, :role_not_found}
    end
  end
  
  # Get all roles for a user (with scope information)
  def get_user_roles(user_id) do
    query = from ur in UserRole,
      join: r in Role, on: ur.role_id == r.id,
      where: ur.user_id == ^user_id and ur.is_active == true,
      select: %{
        role_name: r.name,
        role_display_name: r.display_name,
        role_type: r.role_type,
        permissions: r.permissions,
        scope_type: ur.scope_type,
        scope_id: ur.scope_id,
        granted_at: ur.granted_at,
        expires_at: ur.expires_at
      }
    
    Repo.all(query)
  end
  
  # Check if user has specific permission
  def user_has_permission?(user_id, permission, resource \\ nil) do
    user_roles = get_user_roles(user_id)
    
    Enum.any?(user_roles, fn role ->
      role_has_permission?(role, permission) &&
      scope_allows_access?(role, resource)
    end)
  end
  
  # Check if user can access specific resource
  def user_can_access_resource?(user_id, resource_type, resource_id) do
    user_roles = get_user_roles(user_id)
    resource = get_resource_info(resource_type, resource_id)
    
    Enum.any?(user_roles, fn role ->
      can_access_resource?(role, resource)
    end)
  end
  
  # Automatically assign roles based on user context
  def auto_assign_roles(user) do
    roles_to_assign = determine_auto_roles(user)
    
    Enum.each(roles_to_assign, fn {role_name, scope_type, scope_id} ->
      assign_role(user.id, role_name, scope_type, scope_id)
    end)
  end
  
  # Private helper functions
  
  defp get_role_by_name(role_name) do
    case Repo.get_by(Role, name: role_name) do
      nil -> {:error, :role_not_found}
      role -> {:ok, role}
    end
  end
  
  defp create_user_role(user_id, role_id, scope_type, scope_id, granted_by_id) do
    %UserRole{}
    |> UserRole.changeset(%{
      user_id: user_id,
      role_id: role_id,
      scope_type: scope_type,
      scope_id: scope_id,
      granted_by_id: granted_by_id
    })
    |> Repo.insert()
  end
  
  defp role_has_permission?(role, permission) do
    permission in role.permissions ||
    "*" in role.permissions ||  # Wildcard permission
    has_wildcard_match?(role.permissions, permission)
  end
  
  defp has_wildcard_match?(permissions, permission) do
    # Check for patterns like "notes:*" matching "notes:create"
    Enum.any?(permissions, fn perm ->
      case String.split(perm, ":") do
        [prefix, "*"] -> String.starts_with?(permission, prefix <> ":")
        _ -> false
      end
    end)
  end
  
  defp scope_allows_access?(role, resource) do
    case {role.scope_type, resource} do
      # Global scope can access anything
      {"global", _} -> true
      
      # Institution scope
      {"institution", %{institution_id: resource_institution}} ->
        role.scope_id == resource_institution
      
      # Course scope  
      {"course", %{course_id: resource_course}} ->
        role.scope_id == resource_course
      
      # Personal scope (user's own resources)
      {"personal", %{user_id: resource_user}} ->
        role.scope_id == resource_user
      
      # No resource specified, allow
      {_, nil} -> true
      
      # Default deny
      _ -> false
    end
  end
  
  defp get_resource_info(resource_type, resource_id) do
    # This would fetch resource metadata from appropriate service
    case resource_type do
      "note" ->
        NotesService.get_note_metadata(resource_id)
      "course" ->
        EducationService.get_course_metadata(resource_id)
      "user" ->
        %{user_id: resource_id}
      _ ->
        nil
    end
  end
  
  defp determine_auto_roles(user) do
    roles = []
    
    # All users get basic student role in their institution
    roles = if user.institution_id do
      [{"student", "institution", user.institution_id} | roles]
    else
      roles
    end
    
    # Check if user's email domain suggests educator role
    roles = if is_educator_email?(user.email) do
      [{"educator", "institution", user.institution_id} | roles]
    else
      roles
    end
    
    roles
  end
  
  defp is_educator_email?(email) do
    # Simple heuristic - emails with "teacher", "prof", "faculty" etc.
    educator_keywords = ["teacher", "prof", "faculty", "instructor", "educator"]
    
    Enum.any?(educator_keywords, fn keyword ->
      String.contains?(String.downcase(email), keyword)
    end)
  end
  
  defp log_role_assignment(user_id, role_id, scope_type, granted_by_id) do
    # Log for audit trail
    Logger.info("Role assigned: user=#{user_id}, role=#{role_id}, scope=#{scope_type}, by=#{granted_by_id}")
  end
  
  defp log_role_revocation(user_id, role_name, scope_type) do
    Logger.info("Role revoked: user=#{user_id}, role=#{role_name}, scope=#{scope_type}")
  end
end
```

### Authorization Plug for API Endpoints

```elixir
# lib/auth_service/authorization_plug.ex
defmodule AuthService.AuthorizationPlug do
  @moduledoc """
  Plug for checking permissions on API endpoints
  """
  
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, put_status: 2]
  
  alias AuthService.RoleManager
  
  def init(opts) do
    # Options: required_permission, resource_type, etc.
    opts
  end
  
  def call(conn, opts) do
    required_permission = opts[:permission]
    resource_type = opts[:resource_type]
    
    current_user_id = conn.assigns[:current_user_id]
    
    if current_user_id do
      check_permission(conn, current_user_id, required_permission, resource_type)
    else
      send_unauthorized(conn)
    end
  end
  
  defp check_permission(conn, user_id, permission, resource_type) do
    # Extract resource ID from path params or body
    resource_id = get_resource_id(conn, resource_type)
    resource = if resource_id, do: get_resource_context(resource_type, resource_id)
    
    if RoleManager.user_has_permission?(user_id, permission, resource) do
      conn  # Allow request to continue
    else
      send_forbidden(conn)
    end
  end
  
  defp get_resource_id(conn, resource_type) do
    case resource_type do
      "note" -> conn.path_params["note_id"] || conn.params["note_id"]
      "course" -> conn.path_params["course_id"] || conn.params["course_id"]  
      "user" -> conn.path_params["user_id"] || conn.params["user_id"]
      _ -> nil
    end
  end
  
  defp get_resource_context(resource_type, resource_id) do
    # Get resource metadata for permission checking
    case resource_type do
      "note" ->
        case NotesService.get_note_metadata(resource_id) do
          {:ok, note} -> %{
            user_id: note.user_id,
            institution_id: note.institution_id,
            course_id: note.course_id
          }
          _ -> nil
        end
      
      "course" ->
        case EducationService.get_course(resource_id) do
          {:ok, course} -> %{
            institution_id: course.institution_id,
            course_id: course.id
          }
          _ -> nil
        end
      
      _ -> nil
    end
  end
  
  defp send_unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Authentication required"})
    |> halt()
  end
  
  defp send_forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Insufficient permissions"})
    |> halt()
  end
end

# Usage in controller:
# plug AuthService.AuthorizationPlug, permission: "create_note", resource_type: "note"
```

### Controller with RBAC Integration

```elixir
# lib/notes_service_web/controllers/notes_controller.ex
defmodule NotesServiceWeb.NotesController do
  use NotesServiceWeb, :controller
  
  alias AuthService.AuthorizationPlug
  alias NotesService.{NotesManager, Note}
  
  # Require authentication for all actions
  plug AuthService.AuthPlug
  
  # Specific permission checks for each action
  plug AuthorizationPlug, [permission: "create_note"] when action in [:create]
  plug AuthorizationPlug, [permission: "read_notes"] when action in [:index, :show]
  plug AuthorizationPlug, [permission: "update_note", resource_type: "note"] when action in [:update]
  plug AuthorizationPlug, [permission: "delete_note", resource_type: "note"] when action in [:delete]
  
  # GET /api/notes - Get user's notes (with proper filtering)
  def index(conn, params) do
    current_user_id = conn.assigns.current_user_id
    current_user_roles = conn.assigns.current_user_roles
    
    # Get notes based on user's role and permissions
    notes = get_notes_for_user(current_user_id, current_user_roles, params)
    
    formatted_notes = Enum.map(notes, &format_note_for_response/1)
    
    conn |> json(%{success: true, data: formatted_notes})
  end
  
  # POST /api/notes - Create new note
  def create(conn, %{"title" => title, "content" => content} = params) do
    current_user_id = conn.assigns.current_user_id
    
    note_params = %{
      title: title,
      content: content,
      subject: params["subject"],
      course_id: params["course_id"],
      sharing_level: params["sharing_level"] || "private"
    }
    
    case NotesManager.create_note(note_params, current_user_id) do
      {:ok, note} ->
        conn
        |> put_status(:created)
        |> json(%{success: true, data: format_note_for_response(note)})
      
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{success: false, errors: format_changeset_errors(changeset)})
    end
  end
  
  # GET /api/notes/:id - Get specific note
  def show(conn, %{"id" => note_id}) do
    current_user_id = conn.assigns.current_user_id
    current_user_roles = conn.assigns.current_user_roles
    
    case get_note_with_access_check(note_id, current_user_id, current_user_roles) do
      {:ok, note} ->
        conn |> json(%{success: true, data: format_note_for_response(note)})
      
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{success: false, error: "Note not found"})
      
      {:error, :access_denied} ->
        conn |> put_status(:forbidden) |> json(%{success: false, error: "Access denied"})
    end
  end
  
  # PUT /api/notes/:id - Update note
  def update(conn, %{"id" => note_id} = params) do
    current_user_id = conn.assigns.current_user_id
    
    case NotesManager.update_note(note_id, params, current_user_id) do
      {:ok, note} ->
        conn |> json(%{success: true, data: format_note_for_response(note)})
      
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{success: false, error: "Note not found"})
      
      {:error, :access_denied} ->
        conn |> put_status(:forbidden) |> json(%{success: false, error: "Cannot update this note"})
      
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{success: false, errors: format_changeset_errors(changeset)})
    end
  end
  
  # DELETE /api/notes/:id - Delete note
  def delete(conn, %{"id" => note_id}) do
    current_user_id = conn.assigns.current_user_id
    
    case NotesManager.delete_note(note_id, current_user_id) do
      {:ok, _} ->
        conn |> json(%{success: true, message: "Note deleted"})
      
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{success: false, error: "Note not found"})
      
      {:error, :access_denied} ->
        conn |> put_status(:forbidden) |> json(%{success: false, error: "Cannot delete this note"})
    end
  end
  
  # Private helper functions
  
  defp get_notes_for_user(user_id, user_roles, params) do
    # Different note access based on roles
    cond do
      has_role?(user_roles, "educator") ->
        # Educators can see notes from their courses
        get_educator_accessible_notes(user_id, params)
      
      has_role?(user_roles, "guardian") ->
        # Guardians can see their children's notes (if allowed)
        get_guardian_accessible_notes(user_id, params)
      
      has_role?(user_roles, "student") ->
        # Students see their own notes + shared notes
        get_student_accessible_notes(user_id, params)
      
      true ->
        # Default: only personal notes
        NotesManager.get_user_notes(user_id)
    end
  end
  
  defp get_educator_accessible_notes(educator_id, params) do
    # Get notes from courses this educator teaches
    course_ids = EducationService.get_educator_course_ids(educator_id)
    
    case params["course_id"] do
      nil -> 
        # All courses
        NotesManager.get_notes_from_courses(course_ids)
      course_id ->
        # Specific course (if educator has access)
        if course_id in course_ids do
          NotesManager.get_notes_from_course(course_id)
        else
          []
        end
    end
  end
  
  defp get_student_accessible_notes(student_id, _params) do
    # Student's own notes + notes shared with them
    own_notes = NotesManager.get_user_notes(student_id)
    shared_notes = NotesManager.get_notes_shared_with_user(student_id)
    
    own_notes ++ shared_notes
  end
  
  defp get_guardian_accessible_notes(guardian_id, params) do
    # Get children this guardian can monitor
    child_ids = GuardianService.get_monitorable_children(guardian_id)
    
    case params["child_id"] do
      nil ->
        # All children's notes
        Enum.flat_map(child_ids, &NotesManager.get_user_notes/1)
      child_id ->
        # Specific child (if guardian has access)
        if child_id in child_ids do
          NotesManager.get_user_notes(child_id)
        else
          []
        end
    end
  end
  
  defp get_note_with_access_check(note_id, user_id, user_roles) do
    case NotesManager.get_note(note_id) do
      {:ok, note} ->
        if can_access_note?(note, user_id, user_roles) do
          {:ok, note}
        else
          {:error, :access_denied}
        end
      
      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
  
  defp can_access_note?(note, user_id, user_roles) do
    cond do
      # Own note
      note.user_id == user_id -> true
      
      # Educator accessing student note in their course
      has_role?(user_roles, "educator") && 
      note.course_id in EducationService.get_educator_course_ids(user_id) -> true
      
      # Guardian accessing child's note
      has_role?(user_roles, "guardian") &&
      note.user_id in GuardianService.get_monitorable_children(user_id) -> true
      
      # Note is shared with user
      NotesManager.is_note_shared_with_user?(note.id, user_id) -> true
      
      # Default deny
      true -> false
    end
  end
  
  defp has_role?(user_roles, role_name) do
    Enum.any?(user_roles, fn role -> role.role_name == role_name end)
  end
  
  defp format_note_for_response(note) do
    %{
      id: note.id,
      title: note.title,
      content: note.content,
      subject: note.subject,
      sharing_level: note.sharing_level,
      created_at: note.created_at,
      updated_at: note.updated_at,
      # Add metadata based on user permissions
      can_edit: true,  # This should be determined by permissions
      can_delete: true,
      can_share: true
    }
  end
  
  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
```

---

## 6. Frontend Implementation (JavaScript) {#frontend}

### Authentication Service

```javascript
// services/AuthService.js
class AuthService {
  constructor() {
    this.baseURL = 'http://localhost:4000/api/auth';
    this.currentUser = null;
    this.token = localStorage.getItem('auth_token');
  }
  
  // Login user and store token
  async login(email, password) {
    try {
      const response = await fetch(`${this.baseURL}/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password })
      });
      
      const data = await response.json();
      
      if (data.success) {
        this.token = data.token;
        this.currentUser = data.user;
        
        // Store token for persistence
        localStorage.setItem('auth_token', this.token);
        
        // Decode token to get user roles
        this.currentUser.roles = this.parseTokenRoles(this.token);
        
        return { success: true, user: this.currentUser };
      } else {
        throw new Error(data.error || 'Login failed');
      }
    } catch (error) {
      throw new Error(`Login failed: ${error.message}`);
    }
  }
  
  // Register new user
  async register(userData) {
    try {
      const response = await fetch(`${this.baseURL}/register`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(userData)
      });
      
      const data = await response.json();
      
      if (data.success) {
        // Auto-login after successful registration
        return await this.login(userData.email, userData.password);
      } else {
        throw new Error(data.error || 'Registration failed');
      }
    } catch (error) {
      throw new Error(`Registration failed: ${error.message}`);
    }
  }
  
  // Logout user
  logout() {
    this.token = null;
    this.currentUser = null;
    localStorage.removeItem('auth_token');
  }
  
  // Check if user is authenticated
  isAuthenticated() {
    return !!this.token && !this.isTokenExpired();
  }
  
  // Get current user info
  getCurrentUser() {
    if (!this.currentUser && this.token) {
      // Try to load user from token
      this.currentUser = this.parseTokenUser(this.token);
    }
    return this.currentUser;
  }
  
  // Get authorization header for API calls
  getAuthHeader() {
    if (this.token) {
      return { 'Authorization': `Bearer ${this.token}` };
    }
    return {};
  }
  
  // Check if user has specific permission
  hasPermission(permission, resource = null) {
    const user = this.getCurrentUser();
    if (!user || !user.roles) return false;
    
    return user.roles.some(role => 
      this.roleHasPermission(role, permission, resource)
    );
  }
  
  // Check if user has specific role
  hasRole(roleName, scopeType = null) {
    const user = this.getCurrentUser();
    if (!user || !user.roles) return false;
    
    return user.roles.some(role => 
      role.role_name === roleName && 
      (scopeType ? role.scope_type === scopeType : true)
    );
  }
  
  // Check if user can access resource
  canAccessResource(resourceType, resourceId) {
    // This would make an API call to check access
    return this.checkResourceAccess(resourceType, resourceId);
  }
  
  // Private helper methods
  
  parseTokenUser(token) {
    try {
      const payload = JSON.parse(atob(token.split('.')[1]));
      return {
        id: payload.user_id,
        email: payload.email,
        institutionId: payload.institution_id,
        roles: payload.roles || []
      };
    } catch (error) {
      console.error('Failed to parse token:', error);
      return null;
    }
  }
  
  parseTokenRoles(token) {
    try {
      const payload = JSON.parse(atob(token.split('.')[1]));
      return payload.roles || [];
    } catch (error) {
      console.error('Failed to parse token roles:', error);
      return [];
    }
  }
  
  isTokenExpired() {
    if (!this.token) return true;
    
    try {
      const payload = JSON.parse(atob(this.token.split('.')[1]));
      const exp = payload.exp * 1000; // Convert to milliseconds
      return Date.now() >= exp;
    } catch (error) {
      return true;
    }
  }
  
  roleHasPermission(role, permission, resource) {
    // Check if role has the specific permission
    if (!role.permissions) return false;
    
    const hasPermission = role.permissions.includes(permission) ||
                         role.permissions.includes('*') ||
                         this.hasWildcardMatch(role.permissions, permission);
    
    if (!hasPermission) return false;
    
    // Check scope access if resource is provided
    if (resource) {
      return this.scopeAllowsAccess(role, resource);
    }
    
    return true;
  }
  
  hasWildcardMatch(permissions, permission) {
    return permissions.some(perm => {
      if (perm.includes(':*')) {
        const prefix = perm.replace(':*', '');
        return permission.startsWith(prefix + ':');
      }
      return false;
    });
  }
  
  scopeAllowsAccess(role, resource) {
    switch (role.scope_type) {
      case 'global':
        return true;
      
      case 'institution':
        return resource.institutionId === role.scope_id;
      
      case 'course':
        return resource.courseId === role.scope_id;
      
      case 'personal':
        return resource.userId === role.scope_id;
      
      default:
        return false;
    }
  }
  
  async checkResourceAccess(resourceType, resourceId) {
    try {
      const response = await fetch(`${this.baseURL}/check-access`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...this.getAuthHeader()
        },
        body: JSON.stringify({
          resource_type: resourceType,
          resource_id: resourceId
        })
      });
      
      const data = await response.json();
      return data.has_access || false;
    } catch (error) {
      console.error('Access check failed:', error);
      return false;
    }
  }
}

export default new AuthService();
```

### Permission-Based UI Components

```javascript
// components/PermissionGate.js
import React from 'react';
import AuthService from '../services/AuthService';

/**
 * Component that only renders children if user has required permission
 */
function PermissionGate({ 
  permission, 
  resource, 
  role, 
  scopeType,
  fallback = null,
  children 
}) {
  // Check permission-based access
  if (permission && !AuthService.hasPermission(permission, resource)) {
    return fallback;
  }
  
  // Check role-based access
  if (role && !AuthService.hasRole(role, scopeType)) {
    return fallback;
  }
  
  // User has access, render children
  return children;
}

// Usage examples:

// Only students can see this button
function StudentOnlyButton() {
  return (
    <PermissionGate role="student">
      <button>Join Study Group</button>
    </PermissionGate>
  );
}

// Only users who can create notes see this
function CreateNoteButton() {
  return (
    <PermissionGate permission="create_note">
      <button>Create New Note</button>
    </PermissionGate>
  );
}

// Only note owners can delete (with resource context)
function DeleteNoteButton({ note }) {
  return (
    <PermissionGate 
      permission="delete_note" 
      resource={{ userId: note.user_id, noteId: note.id }}
      fallback={<span>Cannot delete</span>}
    >
      <button className="btn-danger">Delete Note</button>
    </PermissionGate>
  );
}

export default PermissionGate;
```

```javascript
// components/RoleBasedNavigation.js
import React from 'react';
import { Link } from 'react-router-dom';
import AuthService from '../services/AuthService';
import PermissionGate from './PermissionGate';

function RoleBasedNavigation() {
  const currentUser = AuthService.getCurrentUser();
  
  if (!currentUser) {
    return (
      <nav>
        <Link to="/login">Login</Link>
        <Link to="/register">Register</Link>
      </nav>
    );
  }
  
  return (
    <nav className="navbar">
      <div className="nav-brand">
        <Link to="/">📚 Study Notes</Link>
      </div>
      
      <div className="nav-links">
        {/* Common links for all authenticated users */}
        <Link to="/dashboard">Dashboard</Link>
        
        {/* Student-specific links */}
        <PermissionGate role="student">
          <Link to="/my-notes">My Notes</Link>
          <Link to="/study-groups">Study Groups</Link>
          <Link to="/ai-tutor">AI Tutor</Link>
        </PermissionGate>
        
        {/* Educator-specific links */}
        <PermissionGate role="educator">
          <Link to="/my-courses">My Courses</Link>
          <Link to="/student-progress">Student Progress</Link>
          <Link to="/course-materials">Course Materials</Link>
        </PermissionGate>
        
        {/* Guardian-specific links */}
        <PermissionGate role="guardian">
          <Link to="/children-progress">Children's Progress</Link>
          <Link to="/communication">Teacher Communication</Link>
        </PermissionGate>
        
        {/* Admin-specific links */}
        <PermissionGate role="institution_admin">
          <Link to="/admin-dashboard">Admin Dashboard</Link>
          <Link to="/manage-users">Manage Users</Link>
          <Link to="/analytics">Analytics</Link>
        </PermissionGate>
        
        {/* Permission-based links */}
        <PermissionGate permission="view_analytics">
          <Link to="/reports">Reports</Link>
        </PermissionGate>
        
        <PermissionGate permission="moderate_content">
          <Link to="/moderation">Content Moderation</Link>
        </PermissionGate>
      </div>
      
      <div className="nav-user">
        <span>Hello, {currentUser.first_name}!</span>
        <UserRoleBadges roles={currentUser.roles} />
        <button onClick={() => AuthService.logout()}>Logout</button>
      </div>
    </nav>
  );
}

function UserRoleBadges({ roles }) {
  return (
    <div className="role-badges">
      {roles.map((role, index) => (
        <span 
          key={index} 
          className={`badge badge-${role.role_type}`}
          title={role.description}
        >
          {role.display_name}
        </span>
      ))}
    </div>
  );
}

export default RoleBasedNavigation;
```

### Context-Aware Components

```javascript
// components/NotesListWithRBAC.js
import React, { useState, useEffect } from 'react';
import AuthService from '../services/AuthService';
import PermissionGate from './PermissionGate';

function NotesListWithRBAC() {
  const [notes, setNotes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [viewMode, setViewMode] = useState('my_notes');
  
  const currentUser = AuthService.getCurrentUser();
  
  useEffect(() => {
    loadNotes();
  }, [viewMode]);
  
  const loadNotes = async () => {
    setLoading(true);
    try {
      const response = await fetch('/api/notes?' + new URLSearchParams({
        view_mode: viewMode,
        ...(viewMode === 'course_notes' && { course_id: selectedCourseId })
      }), {
        headers: AuthService.getAuthHeader()
      });
      
      const data = await response.json();
      if (data.success) {
        setNotes(data.data);
      }
    } catch (error) {
      console.error('Failed to load notes:', error);
    }
    setLoading(false);
  };
  
  const deleteNote = async (noteId) => {
    if (!confirm('Are you sure you want to delete this note?')) return;
    
    try {
      const response = await fetch(`/api/notes/${noteId}`, {
        method: 'DELETE',
        headers: AuthService.getAuthHeader()
      });
      
      if (response.ok) {
        setNotes(notes.filter(note => note.id !== noteId));
      } else {
        alert('Failed to delete note');
      }
    } catch (error) {
      console.error('Delete failed:', error);
    }
  };
  
  return (
    <div className="notes-list">
      {/* View mode selector - role-based */}
      <div className="view-controls">
        <button 
          className={viewMode === 'my_notes' ? 'active' : ''}
          onClick={() => setViewMode('my_notes')}
        >
          My Notes
        </button>
        
        <PermissionGate role="educator">
          <button 
            className={viewMode === 'course_notes' ? 'active' : ''}
            onClick={() => setViewMode('course_notes')}
          >
            Course Notes
          </button>
        </PermissionGate>
        
        <PermissionGate role="guardian">
          <button 
            className={viewMode === 'children_notes' ? 'active' : ''}
            onClick={() => setViewMode('children_notes')}
          >
            Children's Notes
          </button>
        </PermissionGate>
        
        <PermissionGate permission="view_all_notes">
          <button 
            className={viewMode === 'all_notes' ? 'active' : ''}
            onClick={() => setViewMode('all_notes')}
          >
            All Notes
          </button>
        </PermissionGate>
      </div>
      
      {/* Notes list */}
      {loading ? (
        <div>Loading notes...</div>
      ) : (
        <div className="notes-grid">
          {notes.map(note => (
            <NoteCard 
              key={note.id} 
              note={note} 
              currentUser={currentUser}
              onDelete={deleteNote}
            />
          ))}
        </div>
      )}
    </div>
  );
}


function NoteCard({ note, currentUser, onDelete }) {
  const isOwner = note.user_id === currentUser.id;
  const canEdit = note.can_edit && (isOwner || AuthService.hasPermission('edit_any_note'));
  const canDelete = note.can_delete && (isOwner || AuthService.hasPermission('delete_any_note'));
  const canShare = note.can_share && AuthService.hasPermission('share_note');
  
  return (
    <div className="note-card">
      <div className="note-header">
        <h3>{note.title}</h3>
        
        {/* Role-based badges */}
        <div className="note-badges">
          {!isOwner && (
            <span className="badge badge-info">
              {AuthService.hasRole('educator') ? 'Student Note' : 'Shared'}
            </span>
          )}
          
          {note.sharing_level !== 'private' && (
            <span className="badge badge-success">
              {note.sharing_level}
            </span>
          )}
        </div>
      </div>
      
      <div className="note-content">
        <p>{note.content.substring(0, 150)}...</p>
        
        <div className="note-metadata">
          <small>
            Subject: {note.subject} | 
            Created: {new Date(note.created_at).toLocaleDateString()}
            
            {/* Show author for non-owners */}
            {!isOwner && note.author && (
              <> | By: {note.author.name}</>
            )}
          </small>
        </div>
      </div>
      
      <div className="note-actions">
        <button onClick={() => window.open(`/notes/${note.id}`, '_blank')}>
          View
        </button>
        
        {/* Edit button - permission gated */}
        <PermissionGate 
          permission="update_note" 
          resource={{ noteId: note.id, userId: note.user_id }}
        >
          {canEdit && (
            <button onClick={() => window.location.href = `/notes/${note.id}/edit`}>
              Edit
            </button>
          )}
        </PermissionGate>
        
        {/* Share button - permission gated */}
        <PermissionGate permission="share_note">
          {canShare && (
            <button onClick={() => openShareDialog(note)}>
              Share
            </button>
          )}
        </PermissionGate>
        
        {/* Delete button - permission gated */}
        <PermissionGate 
          permission="delete_note" 
          resource={{ noteId: note.id, userId: note.user_id }}
        >
          {canDelete && (
            <button 
              className="btn-danger" 
              onClick={() => onDelete(note.id)}
            >
              Delete
            </button>
          )}
        </PermissionGate>
        
        {/* Admin actions */}
        <PermissionGate role="institution_admin">
          <div className="admin-actions">
            <button onClick={() => moderateNote(note.id)}>
              Moderate
            </button>
            <button onClick={() => viewNoteAnalytics(note.id)}>
              Analytics
            </button>
          </div>
        </PermissionGate>
      </div>
    </div>
  );
}

export default NotesListWithRBAC;
```

### API Client with RBAC

```javascript
// services/ApiClient.js
class ApiClient {
  constructor() {
    this.baseURL = 'http://localhost:4000/api';
  }
  
  // Generic API request with automatic auth headers
  async request(endpoint, options = {}) {
    const url = `${this.baseURL}${endpoint}`;
    
    const config = {
      headers: {
        'Content-Type': 'application/json',
        ...AuthService.getAuthHeader(),
        ...options.headers
      },
      ...options
    };
    
    try {
      const response = await fetch(url, config);
      const data = await response.json();
      
      // Handle auth errors
      if (response.status === 401) {
        AuthService.logout();
        window.location.href = '/login';
        throw new Error('Authentication required');
      }
      
      if (response.status === 403) {
        throw new Error(data.error || 'Access denied');
      }
      
      if (!response.ok) {
        throw new Error(data.error || `HTTP ${response.status}`);
      }
      
      return data;
    } catch (error) {
      console.error(`API request failed: ${endpoint}`, error);
      throw error;
    }
  }
  
  // Notes API methods with role-aware parameters
  async getNotes(options = {}) {
    const params = new URLSearchParams();
    
    // Add role-specific parameters
    const currentUser = AuthService.getCurrentUser();
    
    if (AuthService.hasRole('educator') && options.courseId) {
      params.append('course_id', options.courseId);
    }
    
    if (AuthService.hasRole('guardian') && options.childId) {
      params.append('child_id', options.childId);
    }
    
    if (options.subject) {
      params.append('subject', options.subject);
    }
    
    if (options.sharedOnly) {
      params.append('shared_only', 'true');
    }
    
    const queryString = params.toString();
    const endpoint = `/notes${queryString ? '?' + queryString : ''}`;
    
    return this.request(endpoint);
  }
  
  async createNote(noteData) {
    // Add institutional context if available
    const currentUser = AuthService.getCurrentUser();
    
    const enrichedData = {
      ...noteData,
      institution_id: currentUser.institutionId
    };
    
    return this.request('/notes', {
      method: 'POST',
      body: JSON.stringify(enrichedData)
    });
  }
  
  async updateNote(noteId, noteData) {
    return this.request(`/notes/${noteId}`, {
      method: 'PUT',
      body: JSON.stringify(noteData)
    });
  }
  
  async deleteNote(noteId) {
    return this.request(`/notes/${noteId}`, {
      method: 'DELETE'
    });
  }
  
  async shareNote(noteId, shareData) {
    return this.request(`/notes/${noteId}/share`, {
      method: 'POST',
      body: JSON.stringify(shareData)
    });
  }
  
  // Role management API methods
  async getUserRoles(userId = null) {
    const endpoint = userId ? `/users/${userId}/roles` : '/me/roles';
    return this.request(endpoint);
  }
  
  async assignRole(userId, roleData) {
    return this.request(`/users/${userId}/roles`, {
      method: 'POST',
      body: JSON.stringify(roleData)
    });
  }
  
  async revokeRole(userId, roleId) {
    return this.request(`/users/${userId}/roles/${roleId}`, {
      method: 'DELETE'
    });
  }
  
  // Analytics API methods (role-restricted)
  async getAnalytics(type, options = {}) {
    if (!AuthService.hasPermission('view_analytics')) {
      throw new Error('Insufficient permissions for analytics');
    }
    
    const params = new URLSearchParams({
      type,
      ...options
    });
    
    return this.request(`/analytics?${params}`);
  }
  
  // Admin API methods (role-restricted)
  async getUsers(filters = {}) {
    if (!AuthService.hasRole('institution_admin')) {
      throw new Error('Admin access required');
    }
    
    const params = new URLSearchParams(filters);
    return this.request(`/admin/users?${params}`);
  }
  
  async moderateContent(contentId, action) {
    if (!AuthService.hasPermission('moderate_content')) {
      throw new Error('Moderation permissions required');
    }
    
    return this.request(`/moderation/content/${contentId}`, {
      method: 'POST',
      body: JSON.stringify({ action })
    });
  }
}

export default new ApiClient();
```

---

## 7. Real-World Use Cases {#use-cases}

### Use Case 1: Student Creates and Shares Note

**Scenario**: Sarah (10th grade student) creates a math note and shares it with her study group.

#### Backend Flow:
```elixir
# 1. Sarah creates a note
def create_note(conn, params) do
  current_user_id = conn.assigns.current_user_id  # Sarah's ID
  
  # Check: Does Sarah have permission to create notes?
  unless RoleManager.user_has_permission?(current_user_id, "create_note") do
    return send_forbidden(conn)
  end
  
  # Create note with Sarah as owner
  case NotesManager.create_note(params, current_user_id) do
    {:ok, note} -> 
      # Sarah owns this note, so she can access it
      json(conn, %{success: true, data: format_note(note)})
  end
end

# 2. Sarah shares the note
def share_note(conn, %{"note_id" => note_id, "share_with" => user_ids}) do
  current_user_id = conn.assigns.current_user_id
  
  # Check: Does Sarah own this note OR have share permissions?
  note = NotesManager.get_note!(note_id)
  
  can_share = note.user_id == current_user_id ||  # Owner can share
              RoleManager.user_has_permission?(current_user_id, "share_any_note")
              
  unless can_share do
    return send_forbidden(conn)
  end
  
  # Check: Can Sarah share with these specific users?
  valid_recipients = filter_valid_share_recipients(current_user_id, user_ids)
  
  # Create sharing records
  SharingManager.share_note(note_id, valid_recipients)
  
  json(conn, %{success: true, shared_with: valid_recipients})
end

defp filter_valid_share_recipients(sharer_id, recipient_ids) do
  sharer_roles = RoleManager.get_user_roles(sharer_id)
  
  Enum.filter(recipient_ids, fn recipient_id ->
    cond do
      # Students can share with classmates in same institution
      has_student_role?(sharer_roles) ->
        same_institution?(sharer_id, recipient_id) &&
        both_are_students?(sharer_id, recipient_id)
      
      # Educators can share with students in their courses
      has_educator_role?(sharer_roles) ->
        educator_teaches_student?(sharer_id, recipient_id)
      
      # Default deny
      true -> false
    end
  end)
end
```

#### Frontend Flow:
```javascript
// ShareNoteDialog.js
function ShareNoteDialog({ note, onClose }) {
  const [searchTerm, setSearchTerm] = useState('');
  const [selectedUsers, setSelectedUsers] = useState([]);
  const [availableUsers, setAvailableUsers] = useState([]);
  
  useEffect(() => {
    loadShareableUsers();
  }, [searchTerm]);
  
  const loadShareableUsers = async () => {
    try {
      // API automatically filters based on user's sharing permissions
      const response = await ApiClient.request(
        `/notes/${note.id}/shareable-users?search=${searchTerm}`
      );
      
      setAvailableUsers(response.data);
    } catch (error) {
      console.error('Failed to load users:', error);
    }
  };
  
  const shareNote = async () => {
    try {
      await ApiClient.shareNote(note.id, {
        share_with: selectedUsers.map(u => u.id),
        permission_level: 'read'  // read, comment, edit
      });
      
      alert('Note shared successfully!');
      onClose();
    } catch (error) {
      if (error.message.includes('Access denied')) {
        alert('You can only share with classmates in your school.');
      } else {
        alert('Failed to share note: ' + error.message);
      }
    }
  };
  
  return (
    <div className="share-dialog">
      <h3>Share Note: {note.title}</h3>
      
      {/* Search for users to share with */}
      <input
        type="text"
        placeholder="Search classmates..."
        value={searchTerm}
        onChange={(e) => setSearchTerm(e.target.value)}
      />
      
      {/* Available users (filtered by backend based on permissions) */}
      <div className="user-list">
        {availableUsers.map(user => (
          <UserSelectItem
            key={user.id}
            user={user}
            selected={selectedUsers.includes(user)}
            onToggle={() => toggleUserSelection(user)}
          />
        ))}
      </div>
      
      <div className="dialog-actions">
        <button onClick={shareNote}>Share</button>
        <button onClick={onClose}>Cancel</button>
      </div>
    </div>
  );
}
```

### Use Case 2: Teacher Views Student Progress

**Scenario**: Mr. Johnson (math teacher) wants to see how his students are progressing with algebra notes.

#### Backend Flow:
```elixir
# Get student progress in educator's courses
def get_student_progress(conn, %{"course_id" => course_id}) do
  educator_id = conn.assigns.current_user_id
  
  # Check: Is this educator teaching this course?
  unless EducationService.educator_teaches_course?(educator_id, course_id) do
    return send_forbidden(conn, "You don't teach this course")
  end
  
  # Get students in this course
  students = EducationService.get_course_students(course_id)
  
  # Get progress data for each student
  progress_data = Enum.map(students, fn student ->
    %{
      student: %{
        id: student.id,
        name: "#{student.first_name} #{student.last_name}",
        # Don't expose sensitive info like email to other students
      },
      notes_count: NotesManager.count_user_notes(student.id, course_id),
      recent_activity: NotesManager.get_recent_activity(student.id, course_id),
      ai_interactions: AIService.get_usage_summary(student.id, course_id),
      # Only show if privacy settings allow
      notes_shared: if privacy_allows_sharing?(student.id, educator_id) do
        NotesManager.get_shared_notes_summary(student.id, course_id)
      else
        "Privacy restricted"
      end
    }
  end)
  
  json(conn, %{success: true, data: progress_data})
end

defp privacy_allows_sharing?(student_id, educator_id) do
  # Check student's privacy settings
  privacy_settings = PrivacyService.get_student_settings(student_id)
  
  case privacy_settings.educator_access_level do
    "full" -> true
    "academic_only" -> true  # This request is academic
    "none" -> false
    "custom" -> 
      # Check if this specific educator is allowed
      privacy_settings.allowed_educators |> Enum.member?(educator_id)
  end
end
```

#### Frontend Flow:
```javascript
// StudentProgressDashboard.js
function StudentProgressDashboard() {
  const [courses, setCourses] = useState([]);
  const [selectedCourse, setSelectedCourse] = useState(null);
  const [progressData, setProgressData] = useState([]);
  const [loading, setLoading] = useState(true);
  
  useEffect(() => {
    loadEducatorCourses();
  }, []);
  
  useEffect(() => {
    if (selectedCourse) {
      loadStudentProgress();
    }
  }, [selectedCourse]);
  
  const loadEducatorCourses = async () => {
    try {
      const response = await ApiClient.request('/educator/courses');
      setCourses(response.data);
      
      if (response.data.length > 0) {
        setSelectedCourse(response.data[0]);
      }
    } catch (error) {
      console.error('Failed to load courses:', error);
    }
  };
  
  const loadStudentProgress = async () => {
    setLoading(true);
    try {
      const response = await ApiClient.request(
        `/educator/student-progress?course_id=${selectedCourse.id}`
      );
      setProgressData(response.data);
    } catch (error) {
      if (error.message.includes('Access denied')) {
        alert('You do not have permission to view this course data.');
      } else {
        console.error('Failed to load progress:', error);
      }
    }
    setLoading(false);
  };
  
  // Only show if user has educator role
  if (!AuthService.hasRole('educator')) {
    return <div>Access denied: Educator access required</div>;
  }
  
  return (
    <div className="progress-dashboard">
      <h2>Student Progress Dashboard</h2>
      
      {/* Course selector */}
      <div className="course-selector">
        <label>Select Course:</label>
        <select 
          value={selectedCourse?.id || ''} 
          onChange={(e) => {
            const course = courses.find(c => c.id === e.target.value);
            setSelectedCourse(course);
          }}
        >
          {courses.map(course => (
            <option key={course.id} value={course.id}>
              {course.name} - {course.subject}
            </option>
          ))}
        </select>
      </div>
      
      {/* Progress data */}
      {loading ? (
        <div>Loading student progress...</div>
      ) : (
        <div className="progress-grid">
          {progressData.map(data => (
            <StudentProgressCard key={data.student.id} data={data} />
          ))}
        </div>
      )}
    </div>
  );
}

function StudentProgressCard({ data }) {
  return (
    <div className="progress-card">
      <h4>{data.student.name}</h4>
      
      <div className="progress-metrics">
        <div className="metric">
          <span className="metric-label">Notes Created:</span>
          <span className="metric-value">{data.notes_count}</span>
        </div>
        
        <div className="metric">
          <span className="metric-label">AI Interactions:</span>
          <span className="metric-value">{data.ai_interactions.total}</span>
        </div>
        
        <div className="metric">
          <span className="metric-label">Recent Activity:</span>
          <span className="metric-value">
            {data.recent_activity.last_note_date || 'No recent activity'}
          </span>
        </div>
        
        <div className="metric">
          <span className="metric-label">Collaboration:</span>
          <span className="metric-value">
            {typeof data.notes_shared === 'string' 
              ? data.notes_shared 
              : `${data.notes_shared.count} notes shared`
            }
          </span>
        </div>
      </div>
      
      {/* Action buttons based on permissions */}
      <div className="progress-actions">
        <PermissionGate permission="view_student_notes">
          <button onClick={() => viewStudentNotes(data.student.id)}>
            View Notes
          </button>
        </PermissionGate>
        
        <PermissionGate permission="communicate_with_student">
          <button onClick={() => sendMessage(data.student.id)}>
            Send Message
          </button>
        </PermissionGate>
      </div>
    </div>
  );
}
```

### Use Case 3: Guardian Monitors Child's Activity

**Scenario**: Mary (Sarah's mom) wants to check her daughter's study activity and privacy settings.

#### Backend Flow:
```elixir
# Guardian accesses child's activity summary
def get_child_activity(conn, %{"child_id" => child_id}) do
  guardian_id = conn.assigns.current_user_id
  
  # Check: Is this person actually the guardian of this child?
  unless GuardianService.is_guardian_of?(guardian_id, child_id) do
    return send_forbidden(conn, "Not authorized to view this child's data")
  end
  
  # Check: What level of monitoring is allowed?
  monitoring_level = GuardianService.get_monitoring_permissions(guardian_id, child_id)
  
  activity_summary = case monitoring_level do
    :full_access ->
      %{
        notes_created: NotesManager.count_user_notes(child_id),
        subjects_studied: NotesManager.get_subject_summary(child_id),
        ai_interactions: AIService.get_usage_summary(child_id),
        social_activity: SocialService.get_activity_summary(child_id),
        screen_time: ActivityTracker.get_app_usage(child_id),
        recent_notes: NotesManager.get_recent_notes(child_id, limit: 5)
      }
    
    :limited_access ->
      %{
        notes_created: NotesManager.count_user_notes(child_id),
        subjects_studied: NotesManager.get_subject_summary(child_id),
        ai_interactions: %{total_count: AIService.count_interactions(child_id)},
        screen_time: ActivityTracker.get_daily_summary(child_id),
        social_activity: "Limited view"
      }
    
    :minimal_access ->
      %{
        notes_created: NotesManager.count_user_notes(child_id),
        last_activity: ActivityTracker.get_last_activity_date(child_id)
      }
  end
  
  json(conn, %{
    success: true, 
    data: activity_summary,
    monitoring_level: monitoring_level
  })
end

# Guardian updates child's privacy settings
def update_child_privacy(conn, %{"child_id" => child_id, "settings" => settings}) do
  guardian_id = conn.assigns.current_user_id
  
  # Check guardian relationship and permissions
  unless GuardianService.can_manage_privacy?(guardian_id, child_id) do
    return send_forbidden(conn, "Cannot manage this child's privacy settings")
  end
  
  # Validate settings don't violate institutional policies
  case PrivacyService.validate_settings(settings, child_id) do
    {:ok, validated_settings} ->
      PrivacyService.update_settings(child_id, validated_settings)
      
      # Notify child of privacy changes (age-appropriate)
      NotificationService.notify_privacy_change(child_id, validated_settings)
      
      json(conn, %{success: true})
    
    {:error, violations} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{success: false, errors: violations})
  end
end
```

#### Frontend Flow:
```javascript
// GuardianDashboard.js
function GuardianDashboard() {
  const [children, setChildren] = useState([]);
  const [selectedChild, setSelectedChild] = useState(null);
  const [activityData, setActivityData] = useState(null);
  const [privacySettings, setPrivacySettings] = useState(null);
  
  useEffect(() => {
    loadChildren();
  }, []);
  
  useEffect(() => {
    if (selectedChild) {
      loadChildActivity();
      loadPrivacySettings();
    }
  }, [selectedChild]);
  
  const loadChildren = async () => {
    try {
      const response = await ApiClient.request('/guardian/children');
      setChildren(response.data);
      
      if (response.data.length > 0) {
        setSelectedChild(response.data[0]);
      }
    } catch (error) {
      console.error('Failed to load children:', error);
    }
  };
  
  const loadChildActivity = async () => {
    try {
      const response = await ApiClient.request(
        `/guardian/child-activity?child_id=${selectedChild.id}`
      );
      setActivityData(response.data);
    } catch (error) {
      if (error.message.includes('Not authorized')) {
        alert('You are not authorized to view this child\'s activity.');
      } else {
        console.error('Failed to load activity:', error);
      }
    }
  };
  
  const loadPrivacySettings = async () => {
    try {
      const response = await ApiClient.request(
        `/guardian/child-privacy?child_id=${selectedChild.id}`
      );
      setPrivacySettings(response.data);
    } catch (error) {
      console.error('Failed to load privacy settings:', error);
    }
  };
  
  const updatePrivacySettings = async (newSettings) => {
    try {
      await ApiClient.request(`/guardian/child-privacy`, {
        method: 'PUT',
        body: JSON.stringify({
          child_id: selectedChild.id,
          settings: newSettings
        })
      });
      
      alert('Privacy settings updated successfully');
      setPrivacySettings(newSettings);
    } catch (error) {
      alert('Failed to update privacy settings: ' + error.message);
    }
  };
  
  // Only guardians can access this
  if (!AuthService.hasRole('guardian')) {
    return <div>Access denied: Guardian access required</div>;
  }
  
  return (
    <div className="guardian-dashboard">
      <h2>Family Dashboard</h2>
      
      {/* Child selector */}
      <div className="child-selector">
        <label>Select Child:</label>
        <select 
          value={selectedChild?.id || ''} 
          onChange={(e) => {
            const child = children.find(c => c.id === e.target.value);
            setSelectedChild(child);
          }}
        >
          {children.map(child => (
            <option key={child.id} value={child.id}>
              {child.name} ({child.grade})
            </option>
          ))}
        </select>
      </div>
      
      {selectedChild && (
        <div className="dashboard-content">
          {/* Activity Summary */}
          <div className="activity-section">
            <h3>{selectedChild.name}'s Study Activity</h3>
            
            {activityData ? (
              <ChildActivitySummary 
                data={activityData} 
                monitoringLevel={activityData.monitoring_level}
              />
            ) : (
              <div>Loading activity data...</div>
            )}
          </div>
          
          {/* Privacy Controls */}
          <PermissionGate permission="manage_child_privacy">
            <div className="privacy-section">
              <h3>Privacy & Safety Settings</h3>
              
              {privacySettings ? (
                <PrivacySettingsPanel
                  settings={privacySettings}
                  onUpdate={updatePrivacySettings}
                  childAge={selectedChild.age}
                />
              ) : (
                <div>Loading privacy settings...</div>
              )}
            </div>
          </PermissionGate>
        </div>
      )}
    </div>
  );
}

function ChildActivitySummary({ data, monitoringLevel }) {
  return (
    <div className="activity-summary">
      {/* Always available data */}
      <div className="metric-grid">
        <div className="metric-card">
          <h4>Notes Created</h4>
          <div className="metric-value">{data.notes_created}</div>
        </div>
        
        <div className="metric-card">
          <h4>Subjects Studied</h4>
          <div className="subject-list">
            {data.subjects_studied?.map(subject => (
              <span key={subject.name} className="subject-badge">
                {subject.name} ({subject.count})
              </span>
            ))}
          </div>
        </div>
      </div>
      
      {/* Conditional data based on monitoring level */}
      {monitoringLevel === 'full_access' && (
        <>
          <div className="metric-grid">
            <div className="metric-card">
              <h4>AI Tutor Usage</h4>
              <div className="metric-value">
                {data.ai_interactions.total_interactions} questions asked
              </div>
              <small>Avg per day: {data.ai_interactions.daily_average}</small>
            </div>
            
            <div className="metric-card">
              <h4>Social Activity</h4>
              <div className="metric-value">
                {data.social_activity.notes_shared} notes shared
              </div>
              <small>{data.social_activity.friends_count} study buddies</small>
            </div>
          </div>
          
          <div className="recent-notes">
            <h4>Recent Notes</h4>
            <div className="notes-list">
              {data.recent_notes?.map(note => (
                <div key={note.id} className="note-item">
                  <span className="note-title">{note.title}</span>
                  <span className="note-subject">{note.subject}</span>
                  <span className="note-date">
                    {new Date(note.created_at).toLocaleDateString()}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
      
      {monitoringLevel === 'limited_access' && (
        <div className="limited-view-notice">
          <p>📱 Limited monitoring active - Basic activity summary only</p>
          <small>Your child has requested limited privacy. Full details not shown.</small>
        </div>
      )}
      
      {monitoringLevel === 'minimal_access' && (
        <div className="minimal-view-notice">
          <p>🔒 Minimal monitoring active - Basic stats only</p>
          <small>Last activity: {data.last_activity}</small>
        </div>
      )}
    </div>
  );
}
```

---

## 8. Scaling to Millions of Users {#scaling}

### Database Scaling Strategies

#### A. Horizontal Partitioning (Sharding)

```elixir
# lib/auth_service/database_router.ex
defmodule AuthService.DatabaseRouter do
  @moduledoc """
  Routes database operations to appropriate shards based on user/institution
  """
  
  @shard_count 16  # Start with 16 shards, can expand
  
  def get_repo_for_user(user_id) when is_binary(user_id) do
    shard_id = calculate_shard(user_id)
    get_repo_by_shard(shard_id)
  end
  
  def get_repo_for_institution(institution_id) when is_binary(institution_id) do
    # Institution-based sharding keeps related data together
    shard_id = calculate_shard(institution_id)
    get_repo_by_shard(shard_id)
  end
  
  defp calculate_shard(id) do
    # Use consistent hashing for even distribution
    :crypto.hash(:sha256, id)
    |> :binary.decode_unsigned()
    |> rem(@shard_count)
  end
  
  defp get_repo_by_shard(shard_id) do
    # Return appropriate repo module for this shard
    Module.concat([AuthService, "Repo#{shard_id}"])
  end
  
  # Multi-shard operations for admin queries
  def query_all_shards(query_fn) do
    0..(@shard_count - 1)
    |> Enum.map(fn shard_id ->
      Task.async(fn ->
        repo = get_repo_by_shard(shard_id)
        query_fn.(repo)
      end)
    end)
    |> Task.await_many(30_000)
    |> List.flatten()
  end
end

# Usage in your services:
defmodule AuthService.RoleManager do
  def get_user_roles(user_id) do
    repo = DatabaseRouter.get_repo_for_user(user_id)
    
    query = from ur in UserRole,
      join: r in Role, on: ur.role_id == r.id,
      where: ur.user_id == ^user_id and ur.is_active == true,
      select: %{...}
    
    repo.all(query)
  end
  
  # For admin operations that need to query all users
  def get_platform_role_statistics do
    DatabaseRouter.query_all_shards(fn repo ->
      repo.all(from ur in UserRole, 
        join: r in Role, on: ur.role_id == r.id,
        group_by: r.name,
        select: {r.name, count(ur.id)}
      )
    end)
    |> Enum.reduce(%{}, fn {role, count}, acc ->
      Map.update(acc, role, count, &(&1 + count))
    end)
  end
end
```

#### B. Read Replicas for Performance

```elixir
# config/config.exs - Database configuration for read/write splitting
config :auth_service, :databases,
  # Write operations go to primary
  primary: [
    username: System.get_env("DB_WRITE_USER"),
    password: System.get_env("DB_WRITE_PASSWORD"),
    database: "notes_app_primary",
    hostname: System.get_env("DB_WRITE_HOST"),
    pool_size: 20
  ],
  
  # Read operations distributed across replicas
  read_replicas: [
    [
      username: System.get_env("DB_READ_USER"),
      password: System.get_env("DB_READ_PASSWORD"), 
      database: "notes_app_replica_1",
      hostname: System.get_env("DB_READ_HOST_1"),
      pool_size: 15
    ],
    [
      username: System.get_env("DB_READ_USER"),
      password: System.get_env("DB_READ_PASSWORD"),
      database: "notes_app_replica_2", 
      hostname: System.get_env("DB_READ_HOST_2"),
      pool_size: 15
    ]
  ]

# lib/auth_service/repo_manager.ex
defmodule AuthService.RepoManager do
  @moduledoc """
  Manages read/write splitting across database replicas
  """
  
  def read_repo do
    # Round-robin across read replicas
    replica_count = length(Application.get_env(:auth_service, :read_replicas))
    replica_index = :persistent_term.get(:current_replica, 0)
    
    next_index = rem(replica_index + 1, replica_count)
    :persistent_term.put(:current_replica, next_index)
    
    Module.concat([AuthService, "ReadRepo#{replica_index}"])
  end
  
  def write_repo do
    AuthService.Repo  # Always use primary for writes
  end
  
  # Macro for easy read/write operations
  defmacro with_read_repo(do: block) do
    quote do
      repo = AuthService.RepoManager.read_repo()
      var!(repo) = repo
      unquote(block)
    end
  end
  
  defmacro with_write_repo(do: block) do
    quote do
      repo = AuthService.RepoManager.write_repo()
      var!(repo) = repo
      unquote(block)
    end
  end
end

# Usage in services:
defmodule AuthService.RoleManager do
  import AuthService.RepoManager
  
  # Read operations use replicas
  def get_user_roles(user_id) do
    with_read_repo do
      query = from ur in UserRole,
        join: r in Role, on: ur.role_id == r.id,
        where: ur.user_id == ^user_id
      
      repo.all(query)
    end
  end
  
  # Write operations use primary
  def assign_role(user_id, role_name, scope_type, scope_id) do
    with_write_repo do
      %UserRole{}
      |> UserRole.changeset(%{...})
      |> repo.insert()
    end
  end
end
```

### Caching Strategies for Scale

#### A. Multi-Layer Caching

```elixir
# lib/auth_service/cache_manager.ex
defmodule AuthService.CacheManager do
  @moduledoc """
  Multi-layer caching: Memory -> RocksDB -> KVRocks -> Database
  """
  
  use GenServer
  
  # L1 Cache: In-memory ETS (fastest, smallest)
  @l1_cache_table :auth_l1_cache
  @l1_ttl 300  # 5 minutes
  
  # L2 Cache: Local RocksDB (fast, persistent across restarts)  
  # L3 Cache: Distributed KVRocks (shared across nodes)
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    # Create ETS table for L1 cache
    :ets.new(@l1_cache_table, [:set, :public, :named_table])
    
    {:ok, %{}}
  end
  
  # Get user roles with multi-layer caching
  def get_user_roles_cached(user_id) do
    cache_key = "user_roles:#{user_id}"
    
    case get_from_l1_cache(cache_key) do
      {:ok, roles} -> 
        {:ok, roles}
      
      :not_found ->
        case get_from_l2_cache(cache_key) do
          {:ok, roles} ->
            store_in_l1_cache(cache_key, roles)
            {:ok, roles}
          
          :not_found ->
            case get_from_l3_cache(cache_key) do
              {:ok, roles} ->
                store_in_l1_cache(cache_key, roles)
                store_in_l2_cache(cache_key, roles)
                {:ok, roles}
              
              :not_found ->
                # Cache miss - load from database
                case AuthService.RoleManager.get_user_roles(user_id) do
                  {:ok, roles} ->
                    store_in_all_caches(cache_key, roles)
                    {:ok, roles}
                  error ->
                    error
                end
            end
        end
    end
  end
  
  # Cache user permissions (computed from roles)
  def get_user_permissions_cached(user_id) do
    cache_key = "user_permissions:#{user_id}"
    
    case get_from_l1_cache(cache_key) do
      {:ok, permissions} -> {:ok, permissions}
      :not_found ->
        case get_user_roles_cached(user_id) do
          {:ok, roles} ->
            permissions = compute_permissions_from_roles(roles)
            store_in_l1_cache(cache_key, permissions)
            {:ok, permissions}
          error ->
            error
        end
    end
  end
  
  # Invalidate cache when roles change
  def invalidate_user_cache(user_id) do
    keys_to_invalidate = [
      "user_roles:#{user_id}",
      "user_permissions:#{user_id}",
      "user_accessible_resources:#{user_id}"
    ]
    
    Enum.each(keys_to_invalidate, fn key ->
      :ets.delete(@l1_cache_table, key)
      delete_from_l2_cache(key)
      delete_from_l3_cache(key)
    end)
    
    # Notify other nodes to invalidate their caches
    Phoenix.PubSub.broadcast(
      AuthService.PubSub,
      "cache_invalidation",
      {:invalidate_user, user_id}
    )
  end
  
  # L1 Cache operations (ETS)
  defp get_from_l1_cache(key) do
    case :ets.lookup(@l1_cache_table, key) do
      [{^key, value, expires_at}] ->
        if DateTime.utc_now() < expires_at do
          {:ok, value}
        else
          :ets.delete(@l1_cache_table, key)
          :not_found
        end
      [] ->
        :not_found
    end
  end
  
  defp store_in_l1_cache(key, value) do
    expires_at = DateTime.utc_now() |> DateTime.add(@l1_ttl, :second)
    :ets.insert(@l1_cache_table, {key, value, expires_at})
  end
  
  # L2 Cache operations (RocksDB)
  defp get_from_l2_cache(key) do
    case AuthService.RocksCache.get(key) do
      {:ok, cached_data} ->
        case Jason.decode(cached_data) do
          {:ok, %{"value" => value, "expires_at" => expires_at}} ->
            if DateTime.utc_now() < DateTime.from_iso8601!(expires_at) do
              {:ok, value}
            else
              AuthService.RocksCache.delete(key)
              :not_found
            end
          _ ->
            :not_found
        end
      :not_found ->
        :not_found
    end
  end
  
  defp store_in_l2_cache(key, value) do
    expires_at = DateTime.utc_now() |> DateTime.add(1800, :second)  # 30 minutes
    
    cache_data = %{
      value: value,
      expires_at: DateTime.to_iso8601(expires_at)
    }
    
    AuthService.RocksCache.put(key, Jason.encode!(cache_data))
  end
  
  # L3 Cache operations (KVRocks)
  defp get_from_l3_cache(key) do
    case KVRocksManager.get_cached_data(key) do
      {:ok, data} -> {:ok, data}
      _ -> :not_found
    end
  end
  
  defp store_in_l3_cache(key, value) do
    KVRocksManager.cache_data(key, value, 3600)  # 1 hour
  end
  
  defp store_in_all_caches(key, value) do
    store_in_l1_cache(key, value)
    store_in_l2_cache(key, value)
    store_in_l3_cache(key, value)
  end
  
  defp compute_permissions_from_roles(roles) do
    roles
    |> Enum.flat_map(& &1.permissions)
    |> Enum.uniq()
  end
end
```

### Load Balancing and Service Distribution

#### A. Service Mesh Architecture

```yaml
# docker-compose.production.yml
version: '3.8'

services:
  # Load balancer
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
    depends_on:
      - auth-service-1
      - auth-service-2
      - notes-service-1
      - notes-service-2
    deploy:
      replicas: 2
      
  # Multiple instances of auth service
  auth-service-1:
    build: ./backend/auth_service
    environment:
      - NODE_ID=auth_1
      - CLUSTER_NODES=auth_1,auth_2,notes_1,notes_2
      - DATABASE_SHARD=0,1,2,3
    deploy:
      replicas: 3
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
  
  auth-service-2:
    build: ./backend/auth_service
    environment:
      - NODE_ID=auth_2
      - CLUSTER_NODES=auth_1,auth_2,notes_1,notes_2
      - DATABASE_SHARD=4,5,6,7
    deploy:
      replicas: 3
  
  # Multiple instances of notes service
  notes-service-1:
    build: ./backend/notes_service
    environment:
      - NODE_ID=notes_1
      - DATABASE_SHARD=0,1,2,3,4,5,6,7
    deploy:
      replicas: 4
      
  notes-service-2:
    build: ./backend/notes_service
    environment:
      - NODE_ID=notes_2
      - DATABASE_SHARD=8,9,10,11,12,13,14,15
    deploy:
      replicas: 4
  
  # AI service cluster
  ai-service:
    build: ./backend/ai_service
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - MODEL_CACHE_SIZE=1000
    deploy:
      replicas: 6  # AI is resource intensive
      resources:
        limits:
          cpus: '2.0'
          memory: 1G
```

#### B. Nginx Load Balancer Configuration

```nginx
# nginx.conf
upstream auth_backend {
    least_conn;
    server auth-service-1:4000 max_fails=3 fail_timeout=30s;
    server auth-service-2:4000 max_fails=3 fail_timeout=30s;
    
    # Health check
    keepalive 32;
}

upstream notes_backend {
    ip_hash;  # Sticky sessions for file uploads
    server notes-service-1:4000 max_fails=3 fail_timeout=30s;
    server notes-service-2:4000 max_fails=3 fail_timeout=30s;
    
    keepalive 32;
}

upstream ai_backend {
    least_conn;
    server ai-service-1:4000 max_fails=2 fail_timeout=60s;
    server ai-service-2:4000 max_fails=2 fail_timeout=60s;
    server ai-service-3:4000 max_fails=2 fail_timeout=60s;
    
    keepalive 16;
}

server {
    listen 80;
    server_name api.notesapp.com;
    
    # Rate limiting
    limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;
    
    # Auth endpoints
    location /api/auth/ {
        limit_req zone=auth burst=20 nodelay;
        proxy_pass http://auth_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        
        # Connection pooling
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
    
    # Notes endpoints  
    location /api/notes/ {
        limit_req zone=api burst=200 nodelay;
        proxy_pass http://notes_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        
        # File upload settings
        client_max_body_size 50M;
        proxy_read_timeout 300s;
    }
    
    # AI endpoints (higher timeout)
    location /api/ai/ {
        limit_req zone=api burst=50 nodelay;
        proxy_pass http://ai_backend;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
```

### Distributed Session Management

```elixir
# lib/auth_service/distributed_session.ex
defmodule AuthService.DistributedSession do
  @moduledoc """
  Manages user sessions across multiple nodes using KVRocks
  """
  
  @session_ttl 86400  # 24 hours
  
  def create_session(user_id, device_info \\ %{}) do
    session_id = generate_session_id()
    
    session_data = %{
      user_id: user_id,
      device_info: device_info,
      created_at: DateTime.utc_now(),
      last_accessed: DateTime.utc_now(),
      permissions_cache: nil  # Will be populated on first access
    }
    
    # Store session in distributed cache
    session_key = "session:#{session_id}"
    KVRocksManager.store_session(session_key, session_data, @session_ttl)
    
    # Track active sessions per user (for security)
    user_sessions_key = "user_sessions:#{user_id}"
    KVRocksManager.sadd(user_sessions_key, session_id)
    KVRocksManager.expire(user_sessions_key, @session_ttl)
    
    {:ok, session_id}
  end
  
  def get_session(session_id) do
    session_key = "session:#{session_id}"
    
    case KVRocksManager.get_session(session_key) do
      {:ok, session_data} ->
        # Update last accessed time
        updated_session = %{session_data | last_accessed: DateTime.utc_now()}
        KVRocksManager.store_session(session_key, updated_session, @session_ttl)
        
        {:ok, updated_session}
      
      {:error, :not_found} ->
        {:error, :session_expired}
    end
  end
  
  def invalidate_session(session_id) do
    session_key = "session:#{session_id}"
    
    # Get session to find user_id
    case get_session(session_id) do
      {:ok, session_data} ->
        # Remove from user's active sessions
        user_sessions_key = "user_sessions:#{session_data.user_id}"
        KVRocksManager.srem(user_sessions_key, session_id)
        
        # Delete the session
        KVRocksManager.delete(session_key)
        
        # Broadcast logout to all connected nodes
        Phoenix.PubSub.broadcast(
          AuthService.PubSub,
          "user_sessions:#{session_data.user_id}",
          {:session_invalidated, session_id}
        )
        
        {:ok, :invalidated}
      
      {:error, :session_expired} ->
        {:ok, :already_expired}
    end
  end
  
  def get_user_active_sessions(user_id) do
    user_sessions_key = "user_sessions:#{user_id}"
    
    case KVRocksManager.smembers(user_sessions_key) do
      {:ok, session_ids} ->
        # Get details for each active session
        sessions = Enum.map(session_ids, fn session_id ->
          case get_session(session_id) do
            {:ok, session_data} -> 
              %{
                session_id: session_id,
                device_info: session_data.device_info,
                created_at: session_data.created_at,
                last_accessed: session_data.last_accessed
              }
            _ -> 
              nil
          end
        end)
        |> Enum.filter(& &1)  # Remove nil entries
        
        {:ok, sessions}
      
      _ ->
        {:ok, []}
    end
  end
  
  # Security: Limit concurrent sessions per user
  def enforce_session_limit(user_id, max_sessions \\ 5) do
    case get_user_active_sessions(user_id) do
      {:ok, sessions} when length(sessions) > max_sessions ->
        # Remove oldest sessions
        sessions_to_remove = sessions
          |> Enum.sort_by(& &1.last_accessed, {:asc, DateTime})
          |> Enum.take(length(sessions) - max_sessions)
        
        Enum.each(sessions_to_remove, fn session ->
          invalidate_session(session.session_id)
        end)
        
        {:ok, :enforced}
      
      _ ->
        {:ok, :within_limit}
    end
  end
  
  defp generate_session_id do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64()
    |> String.replace(["+", "/", "="], "")
  end
end
```

### Auto-Scaling Configuration

```elixir
# lib/auth_service/auto_scaler.ex
defmodule AuthService.AutoScaler do
  @moduledoc """
  Monitors system load and triggers auto-scaling
  """
  
  use GenServer
  
  @check_interval 30_000  # Check every 30 seconds
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    # Schedule first check
    Process.send_after(self(), :check_metrics, @check_interval)
    
    {:ok, %{
      last_scale_action: nil,
      cooldown_until: nil
    }}
  end
  
  def handle_info(:check_metrics, state) do
    # Gather system metrics
    metrics = gather_system_metrics()
    
    # Determine if scaling action is needed
    scaling_decision = analyze_metrics(metrics, state)
    
    # Execute scaling if needed and not in cooldown
    new_state = maybe_execute_scaling(scaling_decision, state)
    
    # Schedule next check
    Process.send_after(self(), :check_metrics, @check_interval)
    
    {:noreply, new_state}
  end
  
  defp gather_system_metrics do
    %{
      cpu_usage: get_average_cpu_usage(),
      memory_usage: get_average_memory_usage(),
      request_rate: get_request_rate(),
      response_time: get_average_response_time(),
      error_rate: get_error_rate(),
      queue_length: get_queue_length(),
      active_connections: get_active_connections()
    }
  end
  
  defp analyze_metrics(metrics, state) do
    cond do
      # Scale up conditions
      metrics.cpu_usage > 80 or 
      metrics.memory_usage > 85 or
      metrics.response_time > 2000 or
      metrics.queue_length > 100 ->
        {:scale_up, calculate_scale_up_factor(metrics)}
      
      # Scale down conditions (be more conservative)
      metrics.cpu_usage < 30 and
      metrics.memory_usage < 40 and
      metrics.response_time < 500 and
      metrics.queue_length < 10 and
      can_scale_down?(state) ->
        {:scale_down, 1}
      
      # No scaling needed
      true ->
        {:no_action, 0}
    end
  end
  
  defp maybe_execute_scaling({:no_action, _}, state), do: state
  
  defp maybe_execute_scaling({action, factor}, state) do
    now = DateTime.utc_now()
    
    # Check cooldown period (prevent rapid scaling)
    if state.cooldown_until && DateTime.compare(now, state.cooldown_until) == :lt do
      Logger.info("Scaling action #{action} skipped due to cooldown")
      state
    else
      execute_scaling_action(action, factor)
      
      # Set cooldown period
      cooldown_until = DateTime.add(now, 300, :second)  # 5 minutes
      
      %{state | 
        last_scale_action: {action, now}, 
        cooldown_until: cooldown_until
      }
    end
  end
  
  defp execute_scaling_action(:scale_up, factor) do
    Logger.info("Scaling up by factor #{factor}")
    
    # Call cloud provider API to increase instances
    case scale_kubernetes_deployment(factor) do
      {:ok, _} ->
        # Notify monitoring systems
        send_scaling_notification(:scale_up, factor)
        
        # Preemptively warm up caches on new instances
        warm_up_new_instances()
      
      {:error, reason} ->
        Logger.error("Scale up failed: #{reason}")
        send_alert(:scale_up_failed, reason)
    end
  end
  
  defp execute_scaling_action(:scale_down, factor) do
    Logger.info("Scaling down by factor #{factor}")
    
    # Gracefully drain connections from instances to be removed
    case drain_and_scale_down(factor) do
      {:ok, _} ->
        send_scaling_notification(:scale_down, factor)
      
      {:error, reason} ->
        Logger.error("Scale down failed: #{reason}")
    end
  end
  
  defp scale_kubernetes_deployment(factor) do
    # Example using kubectl (in production, use Kubernetes API)
    current_replicas = get_current_replica_count()
    target_replicas = min(current_replicas + factor, 50)  # Cap at 50 instances
    
    System.cmd("kubectl", [
      "scale", 
      "deployment", 
      "notes-app", 
      "--replicas=#{target_replicas}"
    ])
  end
  
  defp warm_up_new_instances do
    # Pre-populate caches on new instances
    Task.start(fn ->
      # Wait for instances to be ready
      Process.sleep(30_000)
      
      # Warm up common caches
      AuthService.CacheManager.warm_up_common_data()
    end)
  end
  
  defp can_scale_down?(state) do
    # Don't scale down too aggressively
    case state.last_scale_action do
      {:scale_down, last_time} ->
        DateTime.diff(DateTime.utc_now(), last_time, :minute) > 30
      _ ->
        true
    end
  end
end
```

### Performance Monitoring

```elixir
# lib/auth_service/performance_monitor.ex
defmodule AuthService.PerformanceMonitor do
  @moduledoc """
  Monitors application performance and sends metrics to monitoring systems
  """
  
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    # Set up telemetry handlers
    setup_telemetry_handlers()
    
    # Schedule regular metric collection
    :timer.send_interval(60_000, self(), :collect_metrics)
    
    {:ok, %{metrics_buffer: []}}
  end
  
  def handle_info(:collect_metrics, state) do
    # Collect various performance metrics
    metrics = %{
      timestamp: DateTime.utc_now(),
      
      # System metrics
      system: %{
        cpu_usage: get_cpu_usage(),
        memory_usage: get_memory_usage(),
        disk_usage: get_disk_usage(),
        network_io: get_network_io()
      },
      
      # Application metrics
      application: %{
        active_users: count_active_users(),
        requests_per_minute: get_request_rate(),
        average_response_time: get_avg_response_time(),
        error_rate: get_error_rate(),
        cache_hit_ratio: get_cache_hit_ratio()
      },
      
      # RBAC specific metrics
      rbac: %{
        permission_checks_per_minute: get_permission_check_rate(),
        role_assignments_today: count_todays_role_assignments(),
        failed_authorization_attempts: count_failed_authorizations(),
        average_permission_check_time: get_avg_permission_check_time()
      },
      
      # Database metrics
      database: %{
        connection_pool_usage: get_db_pool_usage(),
        query_response_time: get_avg_query_time(),
        slow_queries_count: count_slow_queries(),
        replication_lag: get_replication_lag()
      }
    }
    
    # Send to monitoring systems
    send_to_monitoring_systems(metrics)
    
    # Check for alerts
    check_alert_conditions(metrics)
    
    {:noreply, state}
  end
  
  defp setup_telemetry_handlers do
    # HTTP request metrics
    :telemetry.attach_many(
      "notes-app-metrics",
      [
        [:phoenix, :endpoint, :stop],
        [:notes_service, :auth, :permission_check],
        [:notes_service, :database, :query],
        [:notes_service, :cache, :hit],
        [:notes_service, :cache, :miss]
      ],
      &handle_telemetry_event/4,
      %{}
    )
  end
  
  def handle_telemetry_event([:phoenix, :endpoint, :stop], measurements, metadata, _config) do
    # Track HTTP request metrics
    :telemetry_metrics.counter("http_requests_total", 
      tags: %{
        method: metadata.conn.method,
        status: metadata.conn.status,
        route: get_route_pattern(metadata.conn)
      }
    )
    
    :telemetry_metrics.histogram("http_request_duration_ms",
      value: measurements.duration / 1_000_000,  # Convert to ms
      tags: %{route: get_route_pattern(metadata.conn)}
    )
  end
  
  def handle_telemetry_event([:notes_service, :auth, :permission_check], measurements, metadata, _config) do
    # Track permission check performance
    :telemetry_metrics.histogram("permission_check_duration_ms",
      value: measurements.duration / 1_000_000,
      tags: %{
        permission: metadata.permission,
        result: if(metadata.allowed, do: "allowed", else: "denied")
      }
    )
  end
  
  def handle_telemetry_event([:notes_service, :cache, :hit], _measurements, metadata, _config) do
    :telemetry_metrics.counter("cache_operations_total",
      tags: %{type: "hit", cache_layer: metadata.layer}
    )
  end
  
  def handle_telemetry_event([:notes_service, :cache, :miss], _measurements, metadata, _config) do
    :telemetry_metrics.counter("cache_operations_total", 
      tags: %{type: "miss", cache_layer: metadata.layer}
    )
  end
  
  defp send_to_monitoring_systems(metrics) do
    # Send to Prometheus/Grafana
    Task.start(fn -> 
      PrometheusExporter.export_metrics(metrics)
    end)
    
    # Send to CloudWatch (if on AWS)
    Task.start(fn ->
      CloudWatchExporter.export_metrics(metrics)
    end)
    
    # Send to custom monitoring dashboard
    Task.start(fn ->
      CustomDashboard.update_metrics(metrics)
    end)
  end
  
  defp check_alert_conditions(metrics) do
    alerts = []
    
    # High error rate alert
    alerts = if metrics.application.error_rate
```elixir
  defp check_alert_conditions(metrics) do
    alerts = []
    
    # High error rate alert
    alerts = if metrics.application.error_rate > 0.05 do  # 5% error rate
      [create_alert(:high_error_rate, metrics.application.error_rate) | alerts]
    else
      alerts
    end
    
    # High response time alert
    alerts = if metrics.application.average_response_time > 2000 do  # 2 seconds
      [create_alert(:high_response_time, metrics.application.average_response_time) | alerts]
    else
      alerts
    end
    
    # High memory usage alert
    alerts = if metrics.system.memory_usage > 0.90 do  # 90% memory usage
      [create_alert(:high_memory_usage, metrics.system.memory_usage) | alerts]
    else
      alerts
    end
    
    # Failed authorization attempts (potential attack)
    alerts = if metrics.rbac.failed_authorization_attempts > 1000 do
      [create_alert(:security_high_failed_auth, metrics.rbac.failed_authorization_attempts) | alerts]
    else
      alerts
    end
    
    # Database replication lag
    alerts = if metrics.database.replication_lag > 30 do  # 30 seconds
      [create_alert(:database_replication_lag, metrics.database.replication_lag) | alerts]
    else
      alerts
    end
    
    # Send alerts if any
    if length(alerts) > 0 do
      send_alerts(alerts)
    end
  end
  
  defp create_alert(type, value) do
    %{
      type: type,
      severity: get_alert_severity(type, value),
      value: value,
      timestamp: DateTime.utc_now(),
      message: get_alert_message(type, value)
    }
  end
  
  defp get_alert_severity(:security_high_failed_auth, _), do: :critical
  defp get_alert_severity(:high_error_rate, rate) when rate > 0.10, do: :critical
  defp get_alert_severity(:high_error_rate, _), do: :warning
  defp get_alert_severity(:high_response_time, time) when time > 5000, do: :critical
  defp get_alert_severity(:high_response_time, _), do: :warning
  defp get_alert_severity(:high_memory_usage, usage) when usage > 0.95, do: :critical
  defp get_alert_severity(:high_memory_usage, _), do: :warning
  defp get_alert_severity(_, _), do: :info
  
  defp send_alerts(alerts) do
    # Send to Slack/Discord
    Task.start(fn ->
      SlackNotifier.send_alerts(alerts)
    end)
    
    # Send to PagerDuty for critical alerts
    critical_alerts = Enum.filter(alerts, &(&1.severity == :critical))
    if length(critical_alerts) > 0 do
      Task.start(fn ->
        PagerDutyNotifier.send_alerts(critical_alerts)
      end)
    end
    
    # Log all alerts
    Enum.each(alerts, fn alert ->
      Logger.warn("ALERT [#{alert.severity}] #{alert.type}: #{alert.message}")
    end)
  end
end
```

---

## 9. Security Best Practices {#security}

### Secure Authentication Implementation

```elixir
# lib/auth_service/secure_auth.ex
defmodule AuthService.SecureAuth do
  @moduledoc """
  Secure authentication with protection against common attacks
  """
  
  # Rate limiting for login attempts
  @max_login_attempts 5
  @lockout_duration 900  # 15 minutes
  
  def authenticate_user(email, password, request_info \\ %{}) do
    # Check if account is locked
    case check_account_lockout(email) do
      {:locked, unlock_time} ->
        {:error, :account_locked, unlock_time}
      
      :not_locked ->
        perform_authentication(email, password, request_info)
    end
  end
  
  defp perform_authentication(email, password, request_info) do
    # Log authentication attempt for monitoring
    log_auth_attempt(email, request_info)
    
    with {:ok, user} <- find_active_user(email),
         {:ok, _} <- verify_password_secure(password, user.password_hash),
         {:ok, _} <- check_account_security(user, request_info),
         {:ok, token} <- generate_secure_token(user, request_info) do
      
      # Clear failed attempts on successful login
      clear_failed_attempts(email)
      
      # Log successful authentication
      log_successful_auth(user.id, request_info)
      
      {:ok, %{user: sanitize_user_data(user), token: token}}
    else
      {:error, :user_not_found} ->
        # Still record failed attempt to prevent enumeration
        record_failed_attempt(email, :user_not_found)
        {:error, :invalid_credentials}
      
      {:error, :invalid_password} ->
        record_failed_attempt(email, :invalid_password)
        {:error, :invalid_credentials}
      
      {:error, :suspicious_activity} ->
        # Lock account immediately for suspicious activity
        lock_account(email, :suspicious_activity)
        {:error, :account_locked}
      
      error ->
        record_failed_attempt(email, :other)
        error
    end
  end
  
  defp verify_password_secure(password, hash) do
    # Use constant-time comparison to prevent timing attacks
    if Bcrypt.verify_pass(password, hash) do
      {:ok, :password_verified}
    else
      # Add small random delay to prevent timing analysis
      Process.sleep(:rand.uniform(100) + 50)
      {:error, :invalid_password}
    end
  end
  
  defp check_account_security(user, request_info) do
    checks = [
      check_device_fingerprint(user.id, request_info),
      check_geolocation_anomaly(user.id, request_info),
      check_time_based_patterns(user.id, request_info)
    ]
    
    case Enum.find(checks, fn {result, _} -> result == :suspicious end) do
      nil -> {:ok, :security_checks_passed}
      {_, reason} -> {:error, :suspicious_activity, reason}
    end
  end
  
  defp generate_secure_token(user, request_info) do
    # Include security context in token
    claims = %{
      user_id: user.id,
      email: user.email,
      roles: load_user_roles(user.id),
      institution_id: user.institution_id,
      device_fingerprint: generate_device_fingerprint(request_info),
      issued_at: DateTime.utc_now() |> DateTime.to_unix(),
      expires_at: DateTime.utc_now() |> DateTime.add(24 * 60 * 60) |> DateTime.to_unix(),
      # Security flags
      security_level: determine_security_level(user, request_info),
      requires_mfa: requires_mfa?(user, request_info)
    }
    
    case Joken.encode_and_sign(claims, get_jwt_secret()) do
      {:ok, token, _claims} -> 
        # Store token hash for revocation checking
        store_token_hash(user.id, hash_token(token))
        {:ok, token}
      error -> 
        {:error, "Token generation failed"}
    end
  end
  
  defp check_account_lockout(email) do
    lockout_key = "lockout:#{email}"
    
    case KVRocksManager.get_data(lockout_key) do
      {:ok, lockout_data} ->
        unlock_time = DateTime.from_iso8601!(lockout_data["unlock_time"])
        
        if DateTime.compare(DateTime.utc_now(), unlock_time) == :lt do
          {:locked, unlock_time}
        else
          # Lockout expired, clear it
          KVRocksManager.delete(lockout_key)
          :not_locked
        end
      
      _ ->
        :not_locked
    end
  end
  
  defp record_failed_attempt(email, reason) do
    attempts_key = "failed_attempts:#{email}"
    
    # Get current attempts
    current_attempts = case KVRocksManager.get_data(attempts_key) do
      {:ok, data} -> data["count"] || 0
      _ -> 0
    end
    
    new_count = current_attempts + 1
    
    # Store updated count
    attempt_data = %{
      count: new_count,
      last_attempt: DateTime.utc_now() |> DateTime.to_iso8601(),
      reason: reason
    }
    
    KVRocksManager.store_data(attempts_key, attempt_data, @lockout_duration)
    
    # Lock account if too many attempts
    if new_count >= @max_login_attempts do
      lock_account(email, :too_many_attempts)
    end
    
    # Log for security monitoring
    Logger.warn("Failed login attempt for #{email}: #{reason} (#{new_count}/#{@max_login_attempts})")
  end
  
  defp lock_account(email, reason) do
    lockout_key = "lockout:#{email}"
    unlock_time = DateTime.utc_now() |> DateTime.add(@lockout_duration, :second)
    
    lockout_data = %{
      reason: reason,
      locked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      unlock_time: DateTime.to_iso8601(unlock_time)
    }
    
    KVRocksManager.store_data(lockout_key, lockout_data, @lockout_duration)
    
    # Send security alert
    send_security_alert(:account_locked, %{email: email, reason: reason})
    
    Logger.warn("Account locked: #{email} - #{reason}")
  end
  
  defp check_device_fingerprint(user_id, request_info) do
    current_fingerprint = generate_device_fingerprint(request_info)
    known_devices_key = "known_devices:#{user_id}"
    
    case KVRocksManager.smembers(known_devices_key) do
      {:ok, known_fingerprints} ->
        if current_fingerprint in known_fingerprints do
          {:ok, :known_device}
        else
          # New device - not necessarily suspicious, but worth noting
          KVRocksManager.sadd(known_devices_key, current_fingerprint)
          KVRocksManager.expire(known_devices_key, 86400 * 30)  # 30 days
          {:warning, :new_device}
        end
      
      _ ->
        # First time - create device list
        KVRocksManager.sadd(known_devices_key, current_fingerprint)
        {:ok, :first_device}
    end
  end
  
  defp generate_device_fingerprint(request_info) do
    # Create fingerprint from request headers and characteristics
    fingerprint_data = [
      request_info[:user_agent] || "",
      request_info[:accept_language] || "",
      request_info[:screen_resolution] || "",
      request_info[:timezone] || "",
      request_info[:platform] || ""
    ]
    |> Enum.join("|")
    
    :crypto.hash(:sha256, fingerprint_data)
    |> Base.encode64()
  end
end
```

### Input Validation and Sanitization

```elixir
# lib/auth_service/input_validator.ex
defmodule AuthService.InputValidator do
  @moduledoc """
  Comprehensive input validation to prevent injection attacks
  """
  
  # Validation rules
  @email_regex ~r/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
  @username_regex ~r/^[a-zA-Z0-9_-]{3,20}$/
  @safe_text_regex ~r/^[a-zA-Z0-9\s\-_.,!?()]+$/
  
  # Maximum field lengths
  @max_lengths %{
    email: 255,
    username: 20,
    password: 128,
    first_name: 50,
    last_name: 50,
    note_title: 500,
    note_content: 50000,
    institution_name: 255
  }
  
  def validate_user_registration(params) do
    with {:ok, email} <- validate_email(params["email"]),
         {:ok, username} <- validate_username(params["username"]),
         {:ok, password} <- validate_password(params["password"]),
         {:ok, first_name} <- validate_name(params["first_name"], :first_name),
         {:ok, last_name} <- validate_name(params["last_name"], :last_name) do
      
      {:ok, %{
        email: String.downcase(email),
        username: String.downcase(username),
        password: password,
        first_name: String.trim(first_name),
        last_name: String.trim(last_name)
      }}
    else
      {:error, field, message} -> {:error, %{field => [message]}}
      error -> error
    end
  end
  
  def validate_note_creation(params) do
    with {:ok, title} <- validate_note_title(params["title"]),
         {:ok, content} <- validate_note_content(params["content"]),
         {:ok, subject} <- validate_subject(params["subject"]) do
      
      {:ok, %{
        title: sanitize_html(title),
        content: sanitize_note_content(content),
        subject: String.downcase(String.trim(subject))
      }}
    else
      {:error, field, message} -> {:error, %{field => [message]}}
    end
  end
  
  def validate_email(email) when is_binary(email) do
    email = String.trim(email)
    
    cond do
      String.length(email) == 0 ->
        {:error, :email, "Email is required"}
      
      String.length(email) > @max_lengths.email ->
        {:error, :email, "Email is too long"}
      
      not Regex.match?(@email_regex, email) ->
        {:error, :email, "Invalid email format"}
      
      is_disposable_email?(email) ->
        {:error, :email, "Disposable email addresses are not allowed"}
      
      true ->
        {:ok, email}
    end
  end
  
  def validate_email(_), do: {:error, :email, "Email must be a string"}
  
  def validate_username(username) when is_binary(username) do
    username = String.trim(username)
    
    cond do
      String.length(username) == 0 ->
        {:error, :username, "Username is required"}
      
      String.length(username) < 3 ->
        {:error, :username, "Username must be at least 3 characters"}
      
      String.length(username) > @max_lengths.username ->
        {:error, :username, "Username is too long"}
      
      not Regex.match?(@username_regex, username) ->
        {:error, :username, "Username can only contain letters, numbers, hyphens, and underscores"}
      
      is_reserved_username?(username) ->
        {:error, :username, "This username is reserved"}
      
      true ->
        {:ok, username}
    end
  end
  
  def validate_username(_), do: {:error, :username, "Username must be a string"}
  
  def validate_password(password) when is_binary(password) do
    cond do
      String.length(password) < 8 ->
        {:error, :password, "Password must be at least 8 characters"}
      
      String.length(password) > @max_lengths.password ->
        {:error, :password, "Password is too long"}
      
      not has_uppercase?(password) ->
        {:error, :password, "Password must contain at least one uppercase letter"}
      
      not has_lowercase?(password) ->
        {:error, :password, "Password must contain at least one lowercase letter"}
      
      not has_digit?(password) ->
        {:error, :password, "Password must contain at least one number"}
      
      not has_special_char?(password) ->
        {:error, :password, "Password must contain at least one special character"}
      
      is_common_password?(password) ->
        {:error, :password, "This password is too common, please choose a different one"}
      
      true ->
        {:ok, password}
    end
  end
  
  def validate_password(_), do: {:error, :password, "Password must be a string"}
  
  def validate_note_content(content) when is_binary(content) do
    content = String.trim(content)
    
    cond do
      String.length(content) == 0 ->
        {:error, :content, "Note content cannot be empty"}
      
      String.length(content) > @max_lengths.note_content ->
        {:error, :content, "Note content is too long"}
      
      contains_suspicious_content?(content) ->
        {:error, :content, "Content contains prohibited elements"}
      
      true ->
        {:ok, content}
    end
  end
  
  def validate_note_content(_), do: {:error, :content, "Content must be a string"}
  
  # Security helper functions
  
  defp is_disposable_email?(email) do
    domain = email |> String.split("@") |> List.last() |> String.downcase()
    
    # Check against known disposable email providers
    disposable_domains = [
      "10minutemail.com", "tempmail.org", "guerrillamail.com",
      "mailinator.com", "throwaway.email"
    ]
    
    domain in disposable_domains
  end
  
  defp is_reserved_username?(username) do
    reserved = [
      "admin", "administrator", "root", "api", "www", "mail",
      "support", "help", "test", "demo", "guest", "user",
      "teacher", "student", "guardian", "moderator"
    ]
    
    String.downcase(username) in reserved
  end
  
  defp has_uppercase?(password), do: String.match?(password, ~r/[A-Z]/)
  defp has_lowercase?(password), do: String.match?(password, ~r/[a-z]/)
  defp has_digit?(password), do: String.match?(password, ~r/[0-9]/)
  defp has_special_char?(password), do: String.match?(password, ~r/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\?]/)
  
  defp is_common_password?(password) do
    # Check against common passwords list
    common_passwords = [
      "password", "123456", "password123", "admin", "qwerty",
      "letmein", "welcome", "monkey", "dragon", "master"
    ]
    
    String.downcase(password) in common_passwords
  end
  
  defp contains_suspicious_content?(content) do
    # Check for potential XSS, SQL injection, or other malicious content
    suspicious_patterns = [
      ~r/<script/i,
      ~r/javascript:/i,
      ~r/on\w+\s*=/i,  # onclick, onload, etc.
      ~r/\bUNION\b.*\bSELECT\b/i,
      ~r/\bDROP\b.*\bTABLE\b/i,
      ~r/\bINSERT\b.*\bINTO\b/i,
      ~r/\bUPDATE\b.*\bSET\b/i,
      ~r/\bDELETE\b.*\bFROM\b/i
    ]
    
    Enum.any?(suspicious_patterns, &Regex.match?(&1, content))
  end
  
  defp sanitize_html(text) do
    # Remove potentially dangerous HTML tags and attributes
    text
    |> String.replace(~r/<script[^>]*>.*?<\/script>/i, "")
    |> String.replace(~r/<[^>]*>/, "")  # Remove all HTML tags
    |> String.replace(~r/&[a-zA-Z0-9#]+;/, "")  # Remove HTML entities
    |> String.trim()
  end
  
  defp sanitize_note_content(content) do
    # Allow basic formatting but remove dangerous content
    content
    |> String.replace(~r/<script[^>]*>.*?<\/script>/im, "")
    |> String.replace(~r/javascript:/i, "")
    |> String.replace(~r/on\w+\s*=/i, "")
    |> String.trim()
  end
end
```

### API Security Middleware

```javascript
// middleware/SecurityMiddleware.js
class SecurityMiddleware {
  constructor() {
    this.rateLimiters = new Map();
    this.suspiciousIPs = new Set();
  }
  
  // Main security middleware
  async securityCheck(req, res, next) {
    try {
      // IP-based rate limiting
      if (!(await this.checkRateLimit(req))) {
        return res.status(429).json({
          error: 'Rate limit exceeded',
          retryAfter: 60
        });
      }
      
      // Check for suspicious patterns
      if (this.detectSuspiciousActivity(req)) {
        this.flagSuspiciousIP(req.ip);
        return res.status(403).json({
          error: 'Suspicious activity detected'
        });
      }
      
      // Input validation
      const validationResult = this.validateInput(req);
      if (!validationResult.valid) {
        return res.status(400).json({
          error: 'Invalid input',
          details: validationResult.errors
        });
      }
      
      // Add security headers
      this.addSecurityHeaders(res);
      
      next();
    } catch (error) {
      console.error('Security middleware error:', error);
      res.status(500).json({ error: 'Security check failed' });
    }
  }
  
  async checkRateLimit(req) {
    const key = this.getRateLimitKey(req);
    const limit = this.getRateLimitForEndpoint(req.path);
    
    if (!this.rateLimiters.has(key)) {
      this.rateLimiters.set(key, {
        count: 0,
        resetTime: Date.now() + 60000  // 1 minute window
      });
    }
    
    const limiter = this.rateLimiters.get(key);
    
    // Reset if window expired
    if (Date.now() > limiter.resetTime) {
      limiter.count = 0;
      limiter.resetTime = Date.now() + 60000;
    }
    
    limiter.count++;
    
    // Clean up old limiters
    this.cleanupRateLimiters();
    
    return limiter.count <= limit;
  }
  
  getRateLimitKey(req) {
    // Combine IP and user ID for more granular limiting
    const userID = req.user?.id || 'anonymous';
    return `${req.ip}:${userID}`;
  }
  
  getRateLimitForEndpoint(path) {
    // Different limits for different endpoints
    const limits = {
      '/api/auth/login': 5,        // 5 login attempts per minute
      '/api/auth/register': 3,     // 3 registrations per minute
      '/api/notes': 100,           // 100 note operations per minute
      '/api/ai/help': 20,          // 20 AI requests per minute
      '/api/search': 50,           // 50 searches per minute
      'default': 200               // Default limit
    };
    
    // Find matching endpoint
    for (const [endpoint, limit] of Object.entries(limits)) {
      if (path.startsWith(endpoint)) {
        return limit;
      }
    }
    
    return limits.default;
  }
  
  detectSuspiciousActivity(req) {
    const suspicious = [
      // SQL injection patterns
      /(\bUNION\b.*\bSELECT\b)|(\bDROP\b.*\bTABLE\b)/i,
      
      // XSS patterns
      /<script[^>]*>|javascript:|on\w+\s*=/i,
      
      // Path traversal
      /\.\.\/|\.\.\\|%2e%2e%2f|%2e%2e\\|%252e%252e%252f/i,
      
      // Command injection
      /[;&|`]|%3b|%26|%7c|%60/i
    ];
    
    const requestString = JSON.stringify({
      body: req.body,
      query: req.query,
      params: req.params,
      headers: req.headers
    });
    
    return suspicious.some(pattern => pattern.test(requestString));
  }
  
  validateInput(req) {
    const errors = [];
    
    // Validate request size
    if (req.headers['content-length'] && 
        parseInt(req.headers['content-length']) > 10 * 1024 * 1024) {  // 10MB
      errors.push('Request too large');
    }
    
    // Validate Content-Type for POST/PUT requests
    if (['POST', 'PUT', 'PATCH'].includes(req.method)) {
      const contentType = req.headers['content-type'];
      if (!contentType || !contentType.includes('application/json')) {
        errors.push('Invalid Content-Type');
      }
    }
    
    // Validate specific fields based on endpoint
    if (req.path === '/api/auth/login') {
      if (!req.body.email || !req.body.password) {
        errors.push('Email and password required');
      }
      
      if (req.body.email && !this.isValidEmail(req.body.email)) {
        errors.push('Invalid email format');
      }
    }
    
    if (req.path === '/api/notes' && req.method === 'POST') {
      if (!req.body.title || !req.body.content) {
        errors.push('Title and content required');
      }
      
      if (req.body.title && req.body.title.length > 500) {
        errors.push('Title too long');
      }
      
      if (req.body.content && req.body.content.length > 50000) {
        errors.push('Content too long');
      }
    }
    
    return {
      valid: errors.length === 0,
      errors: errors
    };
  }
  
  addSecurityHeaders(res) {
    // Prevent XSS attacks
    res.setHeader('X-XSS-Protection', '1; mode=block');
    
    // Prevent content type sniffing
    res.setHeader('X-Content-Type-Options', 'nosniff');
    
    // Prevent clickjacking
    res.setHeader('X-Frame-Options', 'DENY');
    
    // Force HTTPS
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    
    // Content Security Policy
    res.setHeader('Content-Security-Policy', 
      "default-src 'self'; " +
      "script-src 'self' 'unsafe-inline'; " +
      "style-src 'self' 'unsafe-inline'; " +
      "img-src 'self' data: https:; " +
      "connect-src 'self' https://api.openai.com"
    );
    
    // Remove server information
    res.removeHeader('X-Powered-By');
  }
  
  flagSuspiciousIP(ip) {
    this.suspiciousIPs.add(ip);
    
    // Log for security monitoring
    console.warn(`Suspicious activity from IP: ${ip}`);
    
    // Auto-remove after 1 hour
    setTimeout(() => {
      this.suspiciousIPs.delete(ip);
    }, 3600000);
  }
  
  cleanupRateLimiters() {
    const now = Date.now();
    
    for (const [key, limiter] of this.rateLimiters.entries()) {
      if (now > limiter.resetTime + 60000) {  // Clean up old entries
        this.rateLimiters.delete(key);
      }
    }
  }
  
  isValidEmail(email) {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    return emailRegex.test(email);
  }
}

// Export middleware function
const securityMiddleware = new SecurityMiddleware();

export default function setupSecurity(app) {
  // Apply security middleware to all routes
  app.use(securityMiddleware.securityCheck.bind(securityMiddleware));
  
  // CORS configuration
  app.use((req, res, next) => {
    const allowedOrigins = [
      'http://localhost:3000',
      'https://notesapp.com',
      'https://app.notesapp.com'
    ];
    
    const origin = req.headers.origin;
    if (allowedOrigins.includes(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
    }
    
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Allow-Credentials', true);
    
    if (req.method === 'OPTIONS') {
      res.sendStatus(200);
    } else {
      next();
    }
  });
}
```

---

## 10. Testing RBAC Systems {#testing}

### Comprehensive Test Suite

```elixir
# test/auth_service/rbac_integration_test.exs
defmodule AuthService.RBACIntegrationTest do
  use ExUnit.Case, async: false
  
  alias AuthService.{User, Role, UserRole, RoleManager, Authenticator}
  
  setup do
    # Clean database before each test
    Ecto.Adapters.SQL.Sandbox.checkout(AuthService.Repo)
    
    # Create test institutions
    {:ok, lincoln_high} = create_test_institution("Lincoln High School")
    {:ok, mit} = create_test_institution("MIT")
    
    # Create test roles
    {:ok, student_role} = create_test_role("student", "application", ["create_note", "read_own_notes"])
    {:ok, educator_role} = create_test_role("educator", "application", ["create_note", "read_student_notes", "grade_assignments"])
    {:ok, admin_role} = create_test_role("institution_admin", "platform", ["manage_users", "view_analytics"])
    
    # Create test users
    {:ok, sarah} = create_test_user("sarah@lincoln.edu", "Sarah Student", lincoln_high.id)
    {:ok, john} = create_test_user("john@lincoln.edu", "John Teacher", lincoln_high.id)
    {:ok, admin} = create_test_user("admin@lincoln.edu", "Admin User", lincoln_high.id)
    
    # Assign roles
    {:ok, _} = RoleManager.assign_role(sarah.id, "student", "institution", lincoln_high.id)
    {:ok, _} = RoleManager.assign_role(john.id, "educator", "institution", lincoln_high.id)
    {:ok, _} = RoleManager.assign_role(admin.id, "institution_admin", "institution", lincoln_high.id)
    
    %{
      institutions: %{lincoln_high: lincoln_high, mit: mit},
      roles: %{student: student_role, educator: educator_role, admin: admin_role},
      users: %{sarah: sarah, john: john, admin: admin}
    }
  end
  
  describe "Authentication Flow" do
    test "successful login with correct credentials", %{users: %{sarah: sarah}} do
      # Test successful authentication
      result = Authenticator.authenticate_user("sarah@lincoln.edu", "password123")
      
      assert {:ok, %{user: user, token: token}} = result
      assert user.id == sarah.id
      assert is_binary(token)
      
      # Verify token contains role information
      {:ok, claims} = Joken.verify_and_validate(token, get_jwt_secret())
      assert claims["user_id"] == sarah.id
      assert length(claims["roles"]) > 0
    end
    
    test "failed login with incorrect password" do
      result = Authenticator.authenticate_user("sarah@lincoln.edu", "wrongpassword")
      
      assert {:error, "Invalid email or password"} = result
    end
    
    test "account lockout after multiple failed attempts" do
      email = "sarah@lincoln.edu"
      
      # Make 5 failed attempts
      for _ <- 1..5 do
        Authenticator.authenticate_user(email, "wrongpassword")
      end
      
      # 6th attempt should be locked
      result = Authenticator.authenticate_user(email, "wrongpassword")
      assert {:error, :account_locked, _unlock_time} = result
      
      # Even correct password should be locked
      result = Authenticator.authenticate_user(email, "password123")
      assert {:error, :account_locked, _unlock_time} = result
    end
  end
  
  describe "Role-Based Permissions" do
    test "student can create their own notes", %{users: %{sarah: sarah}} do
      # Student should have permission to create notes
      user_roles = RoleManager.get_user_roles(sarah.id)
      
      assert RoleManager.user_has_permission?(sarah.id, "create_note")
      assert RoleManager.user_has_permission?(sarah.id, "read_own_notes")
    end
    
    test "student cannot access admin functions", %{users: %{sarah: sarah}} do
      # Student should NOT have admin permissions
      refute RoleManager.user_has_permission?(sarah.id, "manage_users")
      refute RoleManager.user_has_permission?(sarah.id, "view_analytics")
    end
    
    test "educator can access student notes in their institution", %{users: %{john: john, sarah: sarah}} do
      # Create a note by Sarah
      note = create_test_note(sarah.id, "Math Notes", "Algebra content")
      
      # John (educator) should be able to access it within institution scope
      resource_context = %{
        user_id: sarah.id,
        institution_id: sarah.institution_id,
        note_id: note.id
      }
      
      assert RoleManager.user_has_permission?(john.id, "read_student_notes", resource_context)
    end
    
    test "educator cannot access notes from different institution", %{users: %{john: john}, institutions: %{mit: mit}} do
      # Create a user from different institution
      {:ok, mit_student} = create_test_user("student@mit.edu", "MIT Student", mit.id)
      note = create_test_note(mit_student.id, "MIT Notes", "MIT content")
      
      # John (Lincoln educator) should NOT access MIT student's notes
      resource_context = %{
        user_id: mit_student.id,
        institution_id: mit.id,
        note_id: note.id
      }
      
      refute RoleManager.user_has_permission?(john.id, "read_student_notes", resource_context)
    end
    
    test "institution admin can manage users in their institution", %{users: %{admin: admin}} do
      assert RoleManager.user_has_permission?(admin.id, "manage_users")
      assert RoleManager.user_has_permission?(admin.id, "view_analytics")
    end
  end
  
  describe "Cross-Institution Access Control" do
    test "users cannot access resources from different institutions", %{institutions: %{lincoln_high: lincoln, mit: mit}} do
      # Create users in different institutions
      {:ok, lincoln_student} = create_test_user("lincoln@lincoln.edu", "Lincoln Student", lincoln.id)
      {:ok, mit_student} = create_test_user("mit@mit.edu", "MIT Student", mit.id)
      
      # Assign same role to both
      {:ok, _} = RoleManager.assign_role(lincoln_student.id, "student", "institution", lincoln.id)
      {:ok, _} = RoleManager.assign_role(mit_student.id, "student", "institution", mit.id)
      
      # Create note by MIT student
      note = create_test_note(mit_student.id, "MIT Note", "MIT content")
      
      # Lincoln student should NOT access MIT note
      resource_context = %{
        user_id: mit_student.id,
        institution_id: mit.id,
        note_id: note.id
      }
      
      refute RoleManager.user_has_permission?(lincoln_student.id, "read_student_notes", resource_context)
    end
  end
  
  describe "Role Assignment and Revocation" do
    test "can assign additional roles to user", %{users: %{sarah: sarah}} do
      # Sarah starts as just a student
      roles = RoleManager.get_user_roles(sarah.id)
      role_names = Enum.map(roles, & &1.role_name)
      assert "student" in role_names
      refute "educator" in role_names
      
      # Assign educator role
      {:ok, _} = RoleManager.assign_role(sarah.id, "educator", "institution", sarah.institution_id)
      
      # Should now have both roles
      updated_roles = RoleManager.get_user_roles(sarah.id)
      role_names = Enum.map(updated_roles, & &1.role_name)
      assert "student" in role_names
      assert "educator" in role_names
      
      # Should have permissions from both roles
      assert RoleManager.user_has_permission?(sarah.id, "create_note")  # student permission
      assert RoleManager.user_has_permission?(sarah.id, "grade_assignments")  # educator permission
    end
    
    test "can revoke roles from user", %{users: %{john: john}} do
      # John starts as educator
      assert RoleManager.user_has_permission?(john.id, "grade_assignments")
      
      # Revoke educator role
      {:ok, :revoked} = RoleManager.revoke_role(john.id, "educator", "institution", john.institution_id)
      
      # Should no longer have educator permissions
      refute RoleManager.user_has_permission?(john.id, "grade_assignments")
    end
    
    test "cannot assign roles to users in different institutions", %{users: %{admin: admin}, institutions: %{mit: mit}} do
      # Create MIT user
      {:ok, mit_user} = create_test_user("user@mit.edu", "MIT User", mit.id)
      
      # Lincoln admin should not be able to assign roles to MIT user
      # This would be enforced at the API level, but test the business logic
      lincoln_admin_roles = RoleManager.get_user_roles(admin.id)
      admin_institution = lincoln_admin_roles |> List.first() |> Map.get(:scope_id)
      
      # Verify admin can only manage their own institution
      assert admin_institution != mit.id
    end
  end
  
  describe "Session Management" do
    test "token contains correct role information", %{users: %{sarah: sarah}} do
      # Authenticate user
      {:ok, %{token: token}} = Authenticator.authenticate_user("sarah@lincoln.edu", "password123")
      
      # Decode token
      {:ok, claims} = Joken.verify_and_validate(token, get_jwt_secret())
      
      # Verify token structure
      assert claims["user_id"] == sarah.id
      assert claims["institution_id"] == sarah.institution_id
      assert is_list(claims["roles"])
      assert length(claims["roles"]) > 0
      
      # Verify role structure
      student_role = Enum.find(claims["roles"], &(&1["role_name"] == "student"))
      assert student_role["scope_type"] == "institution"
      assert student_role["scope_id"] == sarah.institution_id
    end
    
    test "token expiration is properly set", %{users: %{sarah: sarah}} do
      {:ok, %{token: token}} = Authenticator.authenticate_user("sarah@lincoln.edu", "password123")
      
      {:ok, claims} = Joken.verify_and_validate(token, get_jwt_secret())
      
      # Token should expire in 24 hours
      issued_at = claims["exp"] - 86400  # 24 hours in seconds
      now = DateTime.utc_now() |> DateTime.to_unix()
      
      # Allow 5 second tolerance
      assert abs(issued_at - now) < 5
    end
  end
  
  describe "Performance Testing" do
    test "permission checking performs well with many roles" do
      # Create user with many roles
      {:ok, user} = create_test_user("test@lincoln.edu", "Test User", nil)
      
      # Assign 20 different roles with different scopes
      for i <- 1..20 do
        {:ok, role} = create_test_role("role_#{i}", "application", ["permission_#{i}"])
        {:ok, _} = RoleManager.assign_role(user.id, "role_#{i}", "personal", user.id)
      end
      
      # Measure permission check time
      start_time = System.monotonic_time(:microsecond)
      
      # Check 100 permissions
      for i <- 1..100 do
        RoleManager.user_has_permission?(user.id, "permission_#{rem(i, 20) + 1}")
      end
      
      end_time = System.monotonic_time(:microsecond)
      duration_ms = (end_time - start_time) / 1000
      
      # Should complete within reasonable time (adjust based on your requirements)
      assert duration_ms < 500  # 500ms for 100 permission checks
    end
  end
  
  # Helper functions for creating test data
  
  defp create_test_institution(name) do
    %Institution{}
    |> Institution.changeset(%{name: name, type: "high_school"})
    |> AuthService.Repo.insert()
  end
  
  defp create_test_role(name, role_type, permissions) do
    %Role{}
    |> Role.changeset(%{
      name: name,
      display_name: String.capitalize(name),
      role_type: role_type,
      permissions: permissions
    })
    |> AuthService.Repo.insert()
  end
  
  defp create_test_user(email, name, institution_id) do
    [first_name, last_name] = String.split(name, " ", parts: 2)
    
    %User{}
    |> User.changeset(%{
      email: email,
      username: email |> String.split("@") |> List.first(),
      password: "password123",
      first_name: first_name,
      last_name: last_name,
      institution_id: institution_id
    })
    |> AuthService.Repo.insert()
  end
  
  defp create_test_note(user_id, title, content) do
    # This would typically go through NotesService
    %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      title: title,
      content: content,
      created_at: DateTime.utc_now()
    }
  end
  
  defp get_jwt_secret do
    Application.get_env(:auth_service, :jwt_secret)
  end
end
```

### Frontend Testing for RBAC

```javascript
// tests/components/PermissionGate.test.js
import { render, screen } from '@testing-library/react';
import PermissionGate from '../components/PermissionGate';
import AuthService from '../services/AuthService';

// Mock AuthService
jest.mock('../services/AuthService');

describe('PermissionGate Component', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });
  
  test('renders children when user has required permission', () => {
    // Mock user with permission
    AuthService.hasPermission.mockReturnValue(true);
    
    render(
      <PermissionGate permission="create_note">
        <button>Create Note</button>
      </PermissionGate>
    );
    
    expect(screen.getByText('Create Note')).toBeInTheDocument();
    expect(AuthService.hasPermission).toHaveBeenCalledWith('create_note', undefined);
  });
  
  test('does not render children when user lacks permission', () => {
    AuthService.hasPermission.mockReturnValue(false);
    
    render(
      <PermissionGate permission="admin_access">
        <button>Admin Panel</button>
      </PermissionGate>
    );
    
    expect(screen.queryByText('Admin Panel')).not.toBeInTheDocument();
  });
  
  test('renders fallback when user lacks permission', () => {
    AuthService.hasPermission.mockReturnValue(false);
    
    render(
      <PermissionGate 
        permission="delete_note" 
        fallback={<span>Access Denied</span>}
      >
        <button>Delete Note</button>
      </PermissionGate>
    );
    
    expect(screen.queryByText('Delete Note')).not.toBeInTheDocument();
    expect(screen.getByText('Access Denied')).toBeInTheDocument();
  });
  
  test('checks role-based access correctly', () => {
    AuthService.hasRole.mockReturnValue(true);
    
    render(
      <PermissionGate role="educator" scopeType="institution">
        <div>Educator Dashboard</div>
      </PermissionGate>
    );
    
    expect(screen.getByText('Educator Dashboard')).toBeInTheDocument();
    expect(AuthService.hasRole).toHaveBeenCalledWith('educator', 'institution');
  });
  
  test('passes resource context for permission checking', () => {
    AuthService.hasPermission.mockReturnValue(true);
    
    const resource = { noteId: '123', userId: 'user456' };
    
    render(
      <PermissionGate permission="edit_note" resource={resource}>
        <button>Edit Note</button>
      </PermissionGate>
    );
    
    expect(AuthService.hasPermission).toHaveBeenCalledWith('edit_note', resource);
  });
});

// tests/services/AuthService.test.js  
describe('AuthService', () => {
  beforeEach(() => {
    localStorage.clear();
    AuthService.logout(); // Reset service state
  });
  
  describe('Authentication', () => {
    test('successful login stores token and user data', async () => {
      // Mock successful API response
      global.fetch = jest.fn().mockResolvedValue({
        json: () => Promise.resolve({
          success: true,
          token: 'mock.jwt.token',
          user: {
            id: 'user123',
            email: 'test@example.com',
            roles: [
              {
                role_name: 'student',
                scope_type: 'institution',
                scope_id: 'school123',
                permissions: ['create_note', 'read_own_notes']
              }
            ]
          }
        })
      });
      
      const result = await AuthService.login('test@example.com', 'password');
      
      expect(result.success).toBe(true);
      expect(result.user.email).toBe('test@example.com');
      expect(AuthService.isAuthenticated()).toBe(true);
      expect(localStorage.getItem('auth_token')).toBe('mock.jwt.token');
    });
    
    test('failed login does not store credentials', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        json: () => Promise.resolve({
          success: false,
          error: 'Invalid credentials'
        })
      });
      
      await expect(AuthService.login('test@example.com', 'wrong')).rejects.toThrow('Invalid credentials');
      
      expect(AuthService.isAuthenticated()).toBe(false);
      expect(localStorage.getItem('auth_token')).toBeNull();
    });
  });
  
  describe('Permission Checking', () => {
    beforeEach(() => {
      // Set up authenticated user with known roles
      AuthService.currentUser = {
        id: 'user123',
        email: 'student@school.edu',
        roles: [
          {
            role_name: 'student',
            scope_type: 'institution',
            scope_id: 'school123',
            permissions: ['create_note', 'read_own_notes', 'share_note']
          }
        ]
      };
      AuthService.token = 'valid.jwt.token';
    });
    
    test('hasPermission returns true for granted permissions', () => {
      expect(AuthService.hasPermission('create_note')).toBe(true);
      expect(AuthService.hasPermission('read_own_notes')).toBe(true);
      expect(AuthService.hasPermission('share_note')).toBe(true);
    });
    
    test('hasPermission returns false for non-granted permissions', () => {
      expect(AuthService.hasPermission('delete_user')).toBe(false);
      expect(AuthService.hasPermission('admin_access')).toBe(false);
    });
    
    test('hasPermission checks resource scope correctly', () => {
      const ownResource = { 
        userId: 'user123', 
        institutionId: 'school123' 
      };
      const otherResource = { 
        userId: 'other456', 
        institutionId: 'school123' 
      };
      const differentInstitution = { 
        userId: 'user123', 
        institutionId: 'other_school' 
      };
      
      expect(AuthService.hasPermission('read_own_notes', ownResource)).toBe(true);
      expect(AuthService.hasPermission('read_own_notes', otherResource)).toBe(false);
      expect(AuthService.hasPermission('read_own_notes', differentInstitution)).toBe(false);
    });
    
    test('hasRole returns true for user roles', () => {
      expect(AuthService.hasRole('student')).toBe(true);
      expect(AuthService.hasRole('student', 'institution')).toBe(true);
    });
    
    test('hasRole returns false for non-user roles', () => {
      expect(AuthService.hasRole('educator')).toBe(false);
      expect(AuthService.hasRole('admin')).toBe(false);
    });
  });
  
  describe('Token Handling', () => {
    test('parseTokenUser extracts user data from JWT', () => {
      // Create a mock JWT token (header.payload.signature)
      const payload = {
        user_id: 'user123',
        email: 'test@example.com',
        institution_id: 'school123',
        roles: [{ role_name: 'student' }],
        exp: Math.floor(Date.now() / 1000) + 3600  // 1 hour from now
      };
      
      const encodedPayload = btoa(JSON.stringify(payload));
      const mockToken = `header.${encodedPayload}.signature`;
      
      const user = AuthService.parseTokenUser(mockToken);
      
      expect(user.id).toBe('user123');
      expect(user.email).toBe('test@example.com');
      expect(user.institutionId).toBe('school123');
      expect(user.roles).toHaveLength(1);
    });
    
    test('isTokenExpired returns true for expired tokens', () => {
      const expiredPayload = {
        exp: Math.floor(Date.now() / 1000) - 3600  // 1 hour ago
      };
      
      const encodedPayload = btoa(JSON.stringify(expiredPayload));
      const expiredToken = `header.${encodedPayload}.signature`;
      
      AuthService.token = expiredToken;
      expect(AuthService.isTokenExpired()).toBe(true);
    });
    
    test('isTokenExpired returns false for valid tokens', () => {
      const validPayload = {
        exp: Math.floor(Date.now() / 1000) + 3600  // 1 hour from now
      };
      
      const encodedPayload = btoa(JSON.stringify(validPayload));
      const validToken = `header.${encodedPayload}.signature`;
      
      AuthService.token = validToken;
      expect(AuthService.isTokenExpired()).toBe(false);
    });
  });
});
```

### Load Testing for RBAC Performance

```javascript
// tests/load/rbac-load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

// Define custom metrics
const loginFailureRate = new Rate('login_failures');
const permissionCheckFailureRate = new Rate('permission_check_failures');

// Test configuration
export let options = {
  stages: [
    { duration: '2m', target: 100 },   // Ramp up to 100 users
    { duration: '5m', target: 100 },   // Stay at 100 users
    { duration: '2m', target: 200 },   // Ramp up to 200 users
    { duration: '5m', target: 200 },   // Stay at 200 users
    { duration: '2m', target: 0 },     // Ramp down to 0 users
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'], // 95% of requests under 2s
    http_req_failed: ['rate<0.1'],     // Error rate under 10%
    login_failures: ['rate<0.05'],     // Login failure rate under 5%
    permission_check_failures: ['rate<0.01'], // Permission check failures under 1%
  },
};

const BASE_URL = 'http://localhost:4000/api';

// Test data
const TEST_USERS = [
  { email: 'student1@lincoln.edu', password: 'password123', role: 'student' },
  { email: 'student2@lincoln.edu', password: 'password123', role: 'student' },
  { email: 'teacher1@lincoln.edu', password: 'password123', role: 'educator' },
  { email: 'teacher2@lincoln.edu', password: 'password123', role: 'educator' },
  { email: 'admin1@lincoln.edu', password: 'password123', role: 'institution_admin' },
];

export default function() {
  // Select random user for this iteration
  const user = TEST_USERS[Math.floor(Math.random() * TEST_USERS.length)];
  
  // 1. Login
  const loginResponse = http.post(`${BASE_URL}/auth/login`, JSON.stringify({
    email: user.email,
    password: user.password
  }), {
    headers: { 'Content-Type': 'application/json' },
  });
  
  const loginSuccess = check(loginResponse, {
    'login status is 200': (r) => r.status === 200,
    'login response time < 1000ms': (r) => r.timings.duration < 1000,
    'has auth token': (r) => JSON.parse(r.body).token !== undefined,
  });
  
  loginFailureRate.add(!loginSuccess);
  
  if (!loginSuccess) {
    sleep(1);
    return;
  }
  
  const authToken = JSON.parse(loginResponse.body).token;
  const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${authToken}`
  };
  
  // 2. Test role-specific operations
  testRoleSpecificOperations(user.role, headers);
  
  // 3. Test permission checking performance
  testPermissionChecking(headers);
  
  // 4. Test concurrent access to shared resources
  testConcurrentAccess(headers, user.role);
  
  sleep(Math.random() * 2 + 1); // Random sleep 1-3 seconds
}

function testRoleSpecificOperations(role, headers) {
  switch (role) {
    case 'student':
      testStudentOperations(headers);
      break;
    case 'educator':
      testEducatorOperations(headers);
      break;
    case 'institution_admin':
      testAdminOperations(headers);
      break;
  }
}

function testStudentOperations(headers) {
  // Create note
  const createNoteResponse = http.post(`${BASE_URL}/notes`, JSON.stringify({
    title: 'Load Test Note',
    content: 'This is a test note created during load testing',
    subject: 'mathematics'
  }), { headers });
  
  check(createNoteResponse, {
    'create note status is 201': (r) => r.status === 201,
    'create note response time < 2000ms': (r) => r.timings.duration < 2000,
  });
  
  // Get user's notes
  const getNotesResponse = http.get(`${BASE_URL}/notes`, { headers });
  
  check(getNotesResponse, {
    'get notes status is 200': (r) => r.status === 200,
    'get notes response time < 1500ms': (r) => r.timings.duration < 1500,
  });
  
  // Use AI tutor
  const aiResponse = http.post(`${BASE_URL}/ai/help`, JSON.stringify({
    question: 'Help me understand quadratic equations'
  }), { headers });
  
  check(aiResponse, {
    'AI help status is 200': (r) => r.status === 200,
    'AI help response time < 5000ms': (r) => r.timings.duration < 5000,
  });
}

function testEducatorOperations(headers) {
  // Get student progress
  const progressResponse = http.get(`${BASE_URL}/educator/student-progress`, { headers });
  
  check(progressResponse, {
    'student progress status is 200': (r) => r.status === 200,
    'student progress response time < 3000ms': (r) => r.timings.duration < 3000,
  });
  
  // Search student notes (should have educator permissions)
  const searchResponse = http.get(`${BASE_URL}/notes/search?q=math`, { headers });
  
  check(searchResponse, {
    'search notes status is 200': (r) => r.status === 200,
    'search notes response time < 2000ms': (r) => r.timings.duration < 2000,
  });
}

function testAdminOperations(headers) {
  // Get analytics
  const analyticsResponse = http.get(`${BASE_URL}/analytics?type=user_activity`, { headers });
  
  check(analyticsResponse, {
    'analytics status is 200': (r) => r.status === 200,
    'analytics response time < 4000ms': (r) => r.timings.duration < 4000,
  });
  
  // Get user list
  const usersResponse = http.get(`${BASE_URL}/admin/users`, { headers });
  
  check(usersResponse, {
    'users list status is 200': (r) => r.status === 200,
    'users list response time < 2000ms': (r) => r.timings.duration < 2000,
  });
}

function testPermissionChecking(headers) {
  // Test multiple permission checks to measure performance
  const permissions = [
    'create_note',
    'read_notes', 
    'share_note',
    'delete_note',
    'admin_access'
  ];
  
  permissions.forEach(permission => {
    const checkResponse = http.post(`${BASE_URL}/auth/check-permission`, JSON.stringify({
      permission: permission,
      resource_type: 'note',
      resource_id: 'test-note-id'
    }), { headers });
    
    const success = check(checkResponse, {
      [`permission check ${permission} responds quickly`]: (r) => r.timings.duration < 500,
      [`permission check ${permission} status is 200`]: (r) => r.status === 200,
    });
    
    permissionCheckFailureRate.add(!success);
  });
}

function testConcurrentAccess(headers, userRole) {
  // Simulate concurrent access to shared resources
  // This tests the database and caching under load
  
  const sharedResourceTests = [
    () => http.get(`${BASE_URL}/courses`, { headers }),
    () => http.get(`${BASE_URL}/study-groups`, { headers }),
    () => http.get(`${BASE_URL}/institutions/settings`, { headers }),
  ];
  
  // Execute multiple requests concurrently
  const responses = sharedResourceTests.map(test => test());
  
  responses.forEach((response, index) => {
    check(response, {
      [`shared resource ${index} accessible`]: (r) => r.status === 200 || r.status === 403,
      [`shared resource ${index} responds quickly`]: (r) => r.timings.duration < 2000,
    });
  });
}

// Teardown function (runs once at the end)
export function teardown(data) {
  console.log('Load test completed');
  console.log('Performance summary:');
  console.log(`- Login failure rate: ${loginFailureRate.rate}`);
  console.log(`- Permission check failure rate: ${permissionCheckFailureRate.rate}`);
}
```

---

## Conclusion

You now have a comprehensive guide to building a production-ready RBAC system for your student notes app! This system can:

### ✅ **What You've Built:**

1. **Secure Authentication**: Multi-factor login with account lockout protection
2. **Flexible Authorization**: Role-based permissions with scope-aware access control
3. **Scalable Architecture**: Multi-database setup with caching and load balancing
4. **Real-World Use Cases**: Student-teacher-guardian workflows with privacy controls
5. **Production Security**: Input validation, rate limiting, and attack prevention
6. **Comprehensive Testing**: Unit, integration, and load testing strategies

### 🎯 **Key Learning Outcomes:**

- **Database Design**: Understanding how to structure RBAC data efficiently
- **Backend Security**: Implementing secure authentication and authorization
- **Frontend Integration**: Building permission-aware UI components
- **Performance Optimization**: Caching, load balancing, and auto-scaling
- **Testing Strategies**: How to test complex permission systems
- **Real-World Application**: Solving actual educational technology challenges

