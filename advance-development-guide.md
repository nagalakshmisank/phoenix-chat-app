# Advanced Product Development Guide: Building Production-Ready P2P Multimedia Notes App

## 🎯 **Overview: From Junior to Confident Full-Stack Developer**

This guide will take junior developers through building a complete **offline/online mobile-first P2P multimedia notes sharing and personal data journaling app** from development to production. You'll learn to build namespace services, data layers, test connections, and deploy a real-world application.

### **What You'll Build: "SyncNotes" - P2P Multimedia Journaling App**

**Core Features:**
- 📱 Mobile-first responsive web app
- 📝 Rich text notes with multimedia attachments
- 🔄 Offline-first with real-time sync
- 👥 P2P sharing and collaboration
- 🔒 End-to-end encryption
- 📊 Personal data analytics and insights
- 🌐 Cross-device synchronization

**Tech Stack:**
- **Frontend**: React Native Web / Progressive Web App
- **Backend**: Elixir/Phoenix with CouchDB integration
- **Database**: CouchDB (documents) + PostgreSQL (metadata)
- **Storage**: S3-compatible (TigrisData/MinIO)
- **Real-time**: Phoenix Channels + WebRTC
- **Testing**: Comprehensive E2E and integration tests

## 🏗️ **Phase 1: Foundation & Namespace Architecture**

### **1.1 Project Structure & Namespaces**

```
syncnotes/
├── apps/
│   ├── mobile-web/              # React Native Web PWA
│   ├── backend-api/             # Phoenix API
│   ├── sync-service/            # CouchDB sync coordinator
│   ├── media-processor/         # Image/video processing
│   └── analytics-service/       # Data insights
├── packages/
│   ├── shared-types/            # TypeScript definitions
│   ├── sync-protocol/           # P2P sync protocols
│   ├── encryption/              # E2E encryption
│   └── data-models/             # Shared data structures
├── services/
│   ├── couchdb/                 # CouchDB configuration
│   ├── storage/                 # S3 storage layer
│   └── namespace-manager/       # Multi-tenant namespacing
└── examples/
    ├── basic-crud/              # Simple CRUD examples
    ├── sync-patterns/           # Offline/online patterns
    ├── media-handling/          # File upload examples
    └── performance-tests/       # Load testing examples
```

### **1.2 Namespace Service Implementation**

```elixir
# apps/backend-api/lib/syncnotes/namespaces/namespace_manager.ex
defmodule SyncNotes.Namespaces.NamespaceManager do
  @moduledoc """
  Manages multi-tenant namespaces for users and organizations
  Each namespace has isolated data and resources
  """
  use GenServer
  
  alias SyncNotes.Accounts.User
  alias SyncNotes.CouchDB.DatabaseManager
  alias SyncNotes.Storage.S3Manager

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new namespace for a user or organization
  """
  def create_namespace(user_id, type \\ :personal) do
    namespace_id = generate_namespace_id(user_id, type)
    
    with {:ok, _} <- create_couchdb_namespace(namespace_id),
         {:ok, _} <- create_s3_namespace(namespace_id),
         {:ok, _} <- setup_sync_replication(namespace_id) do
      {:ok, namespace_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_couchdb_namespace(namespace_id) do
    databases = [
      "#{namespace_id}-notes",      # User notes
      "#{namespace_id}-media",      # Media metadata
      "#{namespace_id}-sync"        # Sync state
    ]
    
    Enum.reduce_while(databases, {:ok, []}, fn db_name, {:ok, acc} ->
      case DatabaseManager.create_database(db_name) do
        {:ok, db} -> {:cont, {:ok, [db | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_s3_namespace(namespace_id) do
    bucket_name = Application.get_env(:syncnotes, :s3_bucket)
    prefix = "namespaces/#{namespace_id}/"
    
    # Create namespace-specific folders
    folders = ["notes/", "media/original/", "media/thumbnails/", "exports/"]
    
    Enum.reduce_while(folders, {:ok, []}, fn folder, {:ok, acc} ->
      case S3Manager.create_folder(bucket_name, prefix <> folder) do
        {:ok, _} -> {:cont, {:ok, [folder | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp setup_sync_replication(namespace_id) do
    # Setup bi-directional replication between user devices
    replication_config = %{
      source: "#{namespace_id}-notes",
      target: "#{namespace_id}-sync",
      continuous: true,
      filter: "sync/user_filter"
    }
    
    DatabaseManager.setup_replication(replication_config)
  end

  defp generate_namespace_id(user_id, type) do
    timestamp = System.os_time(:millisecond)
    hash = :crypto.hash(:sha256, "#{user_id}-#{type}-#{timestamp}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
    
    "ns-#{type}-#{hash}"
  end
end
```

### **1.3 Data Layer Service**

```elixir
# apps/backend-api/lib/syncnotes/data/data_layer.ex
defmodule SyncNotes.Data.DataLayer do
  @moduledoc """
  Central data layer managing CouchDB, PostgreSQL, and S3 operations
  Provides unified interface for all data operations
  """
  
  alias SyncNotes.CouchDB.NotesRepo
  alias SyncNotes.PostgreSQL.MetadataRepo
  alias SyncNotes.Storage.MediaStorage
  
  @doc """
  Create a new note with multimedia attachments
  """
  def create_note(namespace_id, user_id, note_data, attachments \\ []) do
    # Start distributed transaction
    Ecto.Multi.new()
    |> Ecto.Multi.run(:note_id, fn _repo, _changes ->
      {:ok, generate_note_id()}
    end)
    |> Ecto.Multi.run(:couchdb_note, fn _repo, %{note_id: note_id} ->
      create_couchdb_note(namespace_id, note_id, note_data, attachments)
    end)
    |> Ecto.Multi.run(:postgres_metadata, fn _repo, %{note_id: note_id, couchdb_note: note} ->
      create_postgres_metadata(namespace_id, user_id, note_id, note, attachments)
    end)
    |> Ecto.Multi.run(:media_upload, fn _repo, %{note_id: note_id} ->
      upload_attachments(namespace_id, note_id, attachments)
    end)
    |> MetadataRepo.transaction()
    |> case do
      {:ok, result} -> {:ok, result.couchdb_note}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp create_couchdb_note(namespace_id, note_id, note_data, attachments) do
    note_doc = %{
      _id: note_id,
      type: "note",
      title: note_data.title,
      content: note_data.content,
      tags: note_data.tags || [],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      attachments: format_attachments(attachments),
      sync_status: "pending",
      version: 1
    }
    
    NotesRepo.create_document("#{namespace_id}-notes", note_doc)
  end

  defp create_postgres_metadata(namespace_id, user_id, note_id, note, attachments) do
    metadata = %{
      note_id: note_id,
      namespace_id: namespace_id,
      user_id: user_id,
      title: note.title,
      content_preview: String.slice(note.content, 0, 200),
      tags: note.tags,
      attachment_count: length(attachments),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      search_vector: generate_search_vector(note)
    }
    
    MetadataRepo.create_note_metadata(metadata)
  end

  defp upload_attachments(namespace_id, note_id, attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case MediaStorage.upload_file(namespace_id, note_id, attachment) do
        {:ok, uploaded} -> {:cont, {:ok, [uploaded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Sync data between local and remote databases
  """
  def sync_namespace(namespace_id, direction \\ :bidirectional) do
    case direction do
      :bidirectional ->
        with {:ok, _} <- sync_to_remote(namespace_id),
             {:ok, _} <- sync_from_remote(namespace_id) do
          {:ok, :synced}
        end
      :to_remote -> sync_to_remote(namespace_id)
      :from_remote -> sync_from_remote(namespace_id)
    end
  end

  defp sync_to_remote(namespace_id) do
    # Implementation for pushing local changes to remote CouchDB
    local_db = "#{namespace_id}-notes"
    remote_db = "#{get_remote_url()}/#{namespace_id}-notes"
    
    NotesRepo.replicate(local_db, remote_db, continuous: false)
  end

  defp sync_from_remote(namespace_id) do
    # Implementation for pulling remote changes to local CouchDB
    remote_db = "#{get_remote_url()}/#{namespace_id}-notes"
    local_db = "#{namespace_id}-notes"
    
    NotesRepo.replicate(remote_db, local_db, continuous: false)
  end
end
```

## 🧪 **Phase 2: Testing Framework & Connection Validation**

### **2.1 Connection Testing Suite**

```elixir
# test/syncnotes/integration/connection_test.exs
defmodule SyncNotes.Integration.ConnectionTest do
  use ExUnit.Case, async: false
  
  alias SyncNotes.Data.DataLayer
  alias SyncNotes.Namespaces.NamespaceManager
  
  @moduletag :integration

  describe "Database Connections" do
    setup do
      # Create test namespace
      user_id = "test-user-#{:rand.uniform(10000)}"
      {:ok, namespace_id} = NamespaceManager.create_namespace(user_id)
      
      on_exit(fn ->
        # Cleanup test namespace
        cleanup_test_namespace(namespace_id)
      end)
      
      %{namespace_id: namespace_id, user_id: user_id}
    end

    test "CouchDB connection and basic operations", %{namespace_id: namespace_id} do
      # Test database creation
      db_name = "#{namespace_id}-notes"
      assert {:ok, _} = SyncNotes.CouchDB.DatabaseManager.get_database_info(db_name)
      
      # Test document creation
      test_doc = %{
        _id: "test-note-1",
        type: "note",
        title: "Test Note",
        content: "This is a test note"
      }
      
      assert {:ok, created_doc} = SyncNotes.CouchDB.NotesRepo.create_document(db_name, test_doc)
      assert created_doc._id == "test-note-1"
      assert created_doc._rev != nil
      
      # Test document retrieval
      assert {:ok, retrieved_doc} = SyncNotes.CouchDB.NotesRepo.get_document(db_name, "test-note-1")
      assert retrieved_doc.title == "Test Note"
      
      # Test document update
      updated_doc = %{retrieved_doc | title: "Updated Test Note"}
      assert {:ok, _} = SyncNotes.CouchDB.NotesRepo.update_document(db_name, updated_doc)
      
      # Test document deletion
      assert {:ok, _} = SyncNotes.CouchDB.NotesRepo.delete_document(db_name, updated_doc._id, updated_doc._rev)
    end

    test "PostgreSQL metadata operations", %{namespace_id: namespace_id, user_id: user_id} do
      # Test metadata creation
      metadata = %{
        note_id: "test-note-metadata",
        namespace_id: namespace_id,
        user_id: user_id,
        title: "Test Note Metadata",
        content_preview: "This is a preview...",
        tags: ["test", "metadata"],
        attachment_count: 0
      }
      
      assert {:ok, created_metadata} = SyncNotes.PostgreSQL.MetadataRepo.create_note_metadata(metadata)
      assert created_metadata.note_id == "test-note-metadata"
      
      # Test metadata search
      assert {:ok, search_results} = SyncNotes.PostgreSQL.MetadataRepo.search_notes(namespace_id, "test")
      assert length(search_results) > 0
      
      # Test metadata aggregation
      assert {:ok, stats} = SyncNotes.PostgreSQL.MetadataRepo.get_namespace_stats(namespace_id)
      assert stats.total_notes >= 1
    end

    test "S3 storage operations", %{namespace_id: namespace_id} do
      # Test file upload
      test_file = %{
        filename: "test-image.jpg",
        content: "fake image content",
        content_type: "image/jpeg"
      }
      
      assert {:ok, uploaded_file} = SyncNotes.Storage.MediaStorage.upload_file(
        namespace_id, 
        "test-note-1", 
        test_file
      )
      assert uploaded_file.url != nil
      assert uploaded_file.key != nil
      
      # Test file retrieval
      assert {:ok, file_info} = SyncNotes.Storage.MediaStorage.get_file_info(
        namespace_id, 
        uploaded_file.key
      )
      assert file_info.size > 0
      
      # Test file deletion
      assert {:ok, _} = SyncNotes.Storage.MediaStorage.delete_file(namespace_id, uploaded_file.key)
    end

    test "End-to-end data flow", %{namespace_id: namespace_id, user_id: user_id} do
      # Test complete note creation with attachment
      note_data = %{
        title: "E2E Test Note",
        content: "This is an end-to-end test with attachment",
        tags: ["e2e", "test"]
      }
      
      attachments = [
        %{
          filename: "test-attachment.pdf",
          content: "fake pdf content",
          content_type: "application/pdf"
        }
      ]
      
      # Create note with attachment
      assert {:ok, created_note} = DataLayer.create_note(namespace_id, user_id, note_data, attachments)
      assert created_note._id != nil
      assert length(created_note.attachments) == 1
      
      # Verify metadata was created
      assert {:ok, metadata} = SyncNotes.PostgreSQL.MetadataRepo.get_note_metadata(created_note._id)
      assert metadata.attachment_count == 1
      
      # Test sync operation
      assert {:ok, :synced} = DataLayer.sync_namespace(namespace_id, :bidirectional)
    end
  end
end
```

### **2.2 API Endpoint Testing**

```elixir
# test/syncnotes_web/controllers/notes_controller_test.exs
defmodule SyncNotesWeb.NotesControllerTest do
  use SyncNotesWeb.ConnCase, async: false
  
  import SyncNotes.AccountsFixtures
  import SyncNotes.NotesFixtures

  setup %{conn: conn} do
    user = user_fixture()
    namespace_id = "test-ns-#{System.unique_integer()}"
    
    conn = 
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{generate_jwt_token(user)}")
      |> put_req_header("x-namespace-id", namespace_id)
    
    %{conn: conn, user: user, namespace_id: namespace_id}
  end

  describe "POST /api/notes" do
    test "creates note successfully", %{conn: conn, namespace_id: namespace_id} do
      note_params = %{
        title: "API Test Note",
        content: "This note was created via API",
        tags: ["api", "test"]
      }

      conn = post(conn, ~p"/api/notes", note: note_params)
      
      assert %{
        "id" => note_id,
        "title" => "API Test Note",
        "content" => "This note was created via API",
        "tags" => ["api", "test"]
      } = json_response(conn, 201)["data"]
      
      # Verify note exists in CouchDB
      assert {:ok, note} = SyncNotes.CouchDB.NotesRepo.get_document(
        "#{namespace_id}-notes", 
        note_id
      )
      assert note.title == "API Test Note"
    end

    test "creates note with file upload", %{conn: conn} do
      # Simulate file upload
      upload = %Plug.Upload{
        path: "test/fixtures/test-image.jpg",
        filename: "test-image.jpg",
        content_type: "image/jpeg"
      }

      note_params = %{
        title: "Note with Image",
        content: "This note has an image attachment",
        attachments: [upload]
      }

      conn = post(conn, ~p"/api/notes", note: note_params)
      
      assert %{
        "id" => _note_id,
        "title" => "Note with Image",
        "attachments" => [attachment]
      } = json_response(conn, 201)["data"]
      
      assert attachment["filename"] == "test-image.jpg"
      assert attachment["url"] != nil
    end

    test "handles validation errors", %{conn: conn} do
      invalid_params = %{
        title: "",  # Empty title should fail validation
        content: ""
      }

      conn = post(conn, ~p"/api/notes", note: invalid_params)
      
      assert %{
        "error" => "Validation failed",
        "details" => %{
          "title" => ["can't be blank"]
        }
      } = json_response(conn, 422)
    end
  end

  describe "GET /api/notes" do
    setup %{namespace_id: namespace_id} do
      # Create test notes
      notes = [
        note_fixture(%{title: "First Note", namespace_id: namespace_id}),
        note_fixture(%{title: "Second Note", namespace_id: namespace_id}),
        note_fixture(%{title: "Third Note", namespace_id: namespace_id})
      ]
      
      %{notes: notes}
    end

    test "lists all notes for namespace", %{conn: conn, notes: notes} do
      conn = get(conn, ~p"/api/notes")
      
      assert %{
        "data" => returned_notes,
        "pagination" => %{
          "total" => 3,
          "page" => 1,
          "per_page" => 20
        }
      } = json_response(conn, 200)
      
      assert length(returned_notes) == 3
      
      titles = Enum.map(returned_notes, & &1["title"])
      assert "First Note" in titles
      assert "Second Note" in titles
      assert "Third Note" in titles
    end

    test "supports pagination", %{conn: conn} do
      conn = get(conn, ~p"/api/notes?page=1&per_page=2")
      
      assert %{
        "data" => notes,
        "pagination" => %{
          "total" => 3,
          "page" => 1,
          "per_page" => 2
        }
      } = json_response(conn, 200)
      
      assert length(notes) == 2
    end

    test "supports search filtering", %{conn: conn} do
      conn = get(conn, ~p"/api/notes?search=First")
      
      assert %{
        "data" => [note],
        "pagination" => %{"total" => 1}
      } = json_response(conn, 200)
      
      assert note["title"] == "First Note"
    end
  end

  describe "WebSocket real-time updates" do
    test "broadcasts note creation to connected clients", %{namespace_id: namespace_id} do
      # Connect to WebSocket channel
      {:ok, socket} = connect(SyncNotesWeb.UserSocket, %{"token" => generate_jwt_token()})
      {:ok, _, socket} = subscribe_and_join(socket, "notes:#{namespace_id}", %{})
      
      # Create a note via API
      note_params = %{
        title: "Real-time Note",
        content: "This should broadcast to WebSocket"
      }
      
      # This would typically be done via HTTP request in integration test
      {:ok, note} = SyncNotes.Data.DataLayer.create_note(
        namespace_id,
        socket.assigns.user_id,
        note_params
      )
      
      # Verify WebSocket broadcast
      assert_push "note_created", %{
        note: %{
          id: note_id,
          title: "Real-time Note"
        }
      }
      
      assert note_id == note._id
    end
  end
end
```

## 📱 **Phase 3: Frontend Client Implementation**

### **3.1 React Native Web PWA Structure**

```typescript
// apps/mobile-web/src/types/index.ts
export interface Note {
  _id: string;
  _rev?: string;
  title: string;
  content: string;
  tags: string[];
  created_at: string;
  updated_at: string;
  attachments: Attachment[];
  sync_status: 'synced' | 'pending' | 'conflict';
  version: number;
}

export interface Attachment {
  id: string;
  filename: string;
  content_type: string;
  size: number;
  url?: string;
  local_path?: string;
  sync_status: 'synced' | 'pending' | 'uploading';
}

export interface SyncState {
  isOnline: boolean;
  lastSync: string | null;
  pendingChanges: number;
  syncInProgress: boolean;
  conflicts: Note[];
}
```

```typescript
// apps/mobile-web/src/services/DataService.ts
import PouchDB from 'pouchdb';
import PouchDBFind from 'pouchdb-find';
import { Note, Attachment, SyncState } from '../types';

PouchDB.plugin(PouchDBFind);

export class DataService {
  private localDB: PouchDB.Database;
  private remoteDB: PouchDB.Database;
  private syncHandler: PouchDB.Replication.Sync<{}> | null = null;
  private syncState: SyncState = {
    isOnline: navigator.onLine,
    lastSync: null,
    pendingChanges: 0,
    syncInProgress: false,
    conflicts: []
  };

  constructor(namespaceId: string, apiEndpoint: string, authToken: string) {
    this.localDB = new PouchDB(`syncnotes-${namespaceId}-local`, {
      auto_compaction: true
    });
    
    this.remoteDB = new PouchDB(`${apiEndpoint}/couchdb/${namespaceId}-notes`, {
      fetch: (url, opts) => {
        opts = opts || {};
        opts.headers = {
          ...opts.headers,
          'Authorization': `Bearer ${authToken}`
        };
        return PouchDB.fetch(url, opts);
      }
    });

    this.setupSyncHandlers();
    this.setupOfflineHandlers();
    this.createIndexes();
  }

  private async createIndexes(): Promise<void> {
    // Create search indexes for better query performance
    await this.localDB.createIndex({
      index: {
        fields: ['title', 'content', 'tags', 'created_at']
      }
    });
    
    await this.localDB.createIndex({
      index: {
        fields: ['sync_status', 'updated_at']
      }
    });
  }

  private setupSyncHandlers(): void {
    // Setup continuous sync when online
    this.startSync();
    
    // Listen for online/offline events
    window.addEventListener('online', () => {
      this.syncState.isOnline = true;
      this.startSync();
    });
    
    window.addEventListener('offline', () => {
      this.syncState.isOnline = false;
      this.stopSync();
    });
  }

  private setupOfflineHandlers(): void {
    // Monitor local database changes for offline indicators
    this.localDB.changes({
      since: 'now',
      live: true,
      include_docs: true
    }).on('change', (change) => {
      if (change.doc && !change.deleted) {
        const note = change.doc as Note;
        if (note.sync_status === 'pending') {
          this.syncState.pendingChanges++;
        }
      }
    });
  }

  public async createNote(noteData: Omit<Note, '_id' | '_rev' | 'created_at' | 'updated_at' | 'version' | 'sync_status'>): Promise<Note> {
    const now = new Date().toISOString();
    const note: Note = {
      _id: `note-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      ...noteData,
      created_at: now,
      updated_at: now,
      version: 1,
      sync_status: this.syncState.isOnline ? 'pending' : 'pending'
    };

    try {
      const result = await this.localDB.put(note);
      const createdNote = { ...note, _rev: result.rev };
      
      // Trigger immediate sync if online
      if (this.syncState.isOnline) {
        this.triggerSync();
      }
      
      return createdNote;
    } catch (error) {
      throw new Error(`Failed to create note: ${error.message}`);
    }
  }

  public async updateNote(note: Note): Promise<Note> {
    const updatedNote: Note = {
      ...note,
      updated_at: new Date().toISOString(),
      version: note.version + 1,
      sync_status: 'pending'
    };

    try {
      const result = await this.localDB.put(updatedNote);
      const savedNote = { ...updatedNote, _rev: result.rev };
      
      if (this.syncState.isOnline) {
        this.triggerSync();
      }
      
      return savedNote;
    } catch (error) {
      if (error.name === 'conflict') {
        // Handle conflict resolution
        return this.resolveConflict(note);
      }
      throw new Error(`Failed to update note: ${error.message}`);
    }
  }

  public async getNotes(options: {
    limit?: number;
    skip?: number;
    search?: string;
    tags?: string[];
  } = {}): Promise<{ notes: Note[]; total: number }> {
    try {
      let selector: any = {};
      
      if (options.search) {
        selector.$or = [
          { title: { $regex: new RegExp(options.search, 'i') } },
          { content: { $regex: new RegExp(options.search, 'i') } },
          { tags: { $in: [options.search] } }
        ];
      }
      
      if (options.tags && options.tags.length > 0) {
        selector.tags = { $in: options.tags };
      }

      const result = await this.localDB.find({
        selector,
        sort: [{ created_at: 'desc' }],
        limit: options.limit || 20,
        skip: options.skip || 0
      });

      return {
        notes: result.docs as Note[],
        total: result.docs.length
      };
    } catch (error) {
      throw new Error(`Failed to get notes: ${error.message}`);
    }
  }

  public async deleteNote(noteId: string, rev: string): Promise<void> {
    try {
      await this.localDB.remove(noteId, rev);
      
      if (this.syncState.isOnline) {
        this.triggerSync();
      }
    } catch (error) {
      throw new Error(`Failed to delete note: ${error.message}`);
    }
  }

  public async uploadAttachment(noteId: string, file: File): Promise<Attachment> {
    const attachment: Attachment = {
      id: `attachment-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      filename: file.name,
      content_type: file.type,
      size: file.size,
      sync_status: 'uploading'
    };

    try {
      // Store file locally first (for offline support)
      const localPath = await this.storeFileLocally(file);
      attachment.local_path = localPath;

      // Update note with attachment
      const note = await this.localDB.get(noteId) as Note;
      note.attachments = [...note.attachments, attachment];
      note.updated_at = new Date().toISOString();
      note.sync_status = 'pending';
      
      await this.localDB.put(note);

      // Upload to S3 if online
      if (this.syncState.isOnline) {
        try {
          const uploadedUrl = await this.uploadToS3(file, attachment.id);
          attachment.url = uploadedUrl;
          attachment.sync_status = 'synced';
          
          // Update note with synced attachment
          const updatedNote = await this.localDB.get(noteId) as Note;
          updatedNote.attachments = updatedNote.attachments.map(att => 
            att.id === attachment.id ? attachment : att
          );
          await this.localDB.put(updatedNote);
        } catch (uploadError) {
          console.error('Failed to upload to S3, will retry later:', uploadError);
          attachment.sync_status = 'pending';
        }
      }

      return attachment;
    } catch (error) {
      throw new Error(`Failed to upload attachment: ${error.message}`);
    }
  }

  private async storeFileLocally(file: File): Promise<string> {
    // Store file in IndexedDB for offline access
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const localPath = `local-file-${Date.now()}`;
        // Store in IndexedDB (implementation would go here)
        // For now, return a mock path
        resolve(localPath);
      };
      reader.onerror = reject;
      reader.readAsArrayBuffer(file);
    });
  }

  private async uploadToS3(file: File, attachmentId: string): Promise<string> {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('attachment_id', attachmentId);

    const response = await fetch('/api/upload', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${localStorage.getItem('auth_token')}`
      },
      body: formData
    });

    if (!response.ok) {
      throw new Error(`Upload failed: ${response.statusText}`);
    }

    const result = await response.json();
    return result.url;
  }

  private startSync(): void {
    if (!this.syncState.isOnline || this.syncHandler) {
      return;
    }

    this.syncState.syncInProgress = true;
    this.syncHandler = this.localDB.sync(this.remoteDB, {
      live: true,
      retry: true
    })
    .on('change', (change) => {
      console.log('Sync change:', change);
      this.syncState.lastSync = new Date().toISOString();
    })
    .on('paused', () => {
      this.syncState.syncInProgress = false;
      console.log('Sync paused');
    })
    .on('active', () => {
      this.syncState.syncInProgress = true;
      console.log('Sync resumed');
    })
    .on('denied', (err) => {
      console.error('Sync denied:', err);
    })
    .on('complete', () => {
      this.syncState.syncInProgress = false;
      console.log('Sync complete');
    })
    .on('error', (err) => {
      console.error('Sync error:', err);
      this.syncState.syncInProgress = false;
    });
  }

  private stopSync(): void {
    if (this.syncHandler) {
      this.syncHandler.cancel();
      this.syncHandler = null;
      this.syncState.syncInProgress = false;
    }
  }

  private triggerSync(): void {
    if (this.syncHandler) {
      // Trigger a one-time sync
      this.localDB.sync(this.remoteDB, { retry: false });
    }
  }

  private async resolveConflict(note: Note): Promise<Note> {
    try {
      // Get all conflicting revisions
      const conflicts = await this.localDB.get(note._id, { conflicts: true });
      
      // Simple conflict resolution: use latest timestamp
      // In production, you might want more sophisticated resolution
      const latestNote = conflicts._conflicts?.reduce((latest, conflictRev) => {
        // Implementation would compare timestamps and merge changes
        return latest;
      }, note) || note;

      // Save resolved version
      const result = await this.localDB.put(latestNote);
      return { ...latestNote, _rev: result.rev };
    } catch (error) {
      throw new Error(`Failed to resolve conflict: ${error.message}`);
    }
  }

  public getSyncState(): SyncState {
    return { ...this.syncState };
  }
}
```

### **3.2 React Components with Offline Support**

```typescript
// apps/mobile-web/src/components/NotesApp.tsx
import React, { useState, useEffect } from 'react';
import { DataService } from '../services/DataService';
import { Note, SyncState } from '../types';
import { NotesListComponent } from './NotesList';
import { NoteEditorComponent } from './NoteEditor';
import { SyncStatusComponent } from './SyncStatus';
import { SearchComponent } from './Search';

interface NotesAppProps {
  namespaceId: string;
  apiEndpoint: string;
  authToken: string;
}

export const NotesApp: React.FC<NotesAppProps> = ({
  namespaceId,
  apiEndpoint,
  authToken
}) => {
  const [dataService] = useState(() => new DataService(namespaceId, apiEndpoint, authToken));
  const [notes, setNotes] = useState<Note[]>([]);
  const [selectedNote, setSelectedNote] = useState<Note | null>(null);
  const [syncState, setSyncState] = useState<SyncState>(dataService.getSyncState());
  const [isCreating, setIsCreating] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadNotes();
    
    // Set up sync state monitoring
    const syncInterval = setInterval(() => {
      setSyncState(dataService.getSyncState());
    }, 1000);

    return () => clearInterval(syncInterval);
  }, [dataService]);

  useEffect(() => {
    // Reload notes when search query changes
    loadNotes();
  }, [searchQuery]);

  const loadNotes = async () => {
    try {
      setLoading(true);
      const result = await dataService.getNotes({
        search: searchQuery,
        limit: 50
      });
      setNotes(result.notes);
    } catch (error) {
      console.error('Failed to load notes:', error);
    } finally {
      setLoading(false);
    }
  };

  const handleCreateNote = async (noteData: Omit<Note, '_id' | '_rev' | 'created_at' | 'updated_at' | 'version' | 'sync_status'>) => {
    try {
      const newNote = await dataService.createNote(noteData);
      setNotes(prevNotes => [newNote, ...prevNotes]);
      setSelectedNote(newNote);
      setIsCreating(false);
    } catch (error) {
      console.error('Failed to create note:', error);
      alert('Failed to create note. Please try again.');
    }
  };

  const handleUpdateNote = async (updatedNote: Note) => {
    try {
      const savedNote = await dataService.updateNote(updatedNote);
      setNotes(prevNotes => 
        prevNotes.map(note => 
          note._id === savedNote._id ? savedNote : note
        )
      );
      setSelectedNote(savedNote);
    } catch (error) {
      console.error('Failed to update note:', error);
      alert('Failed to update note. Please try again.');
    }
  };

  const handleDeleteNote = async (noteId: string, rev: string) => {
    try {
      await dataService.deleteNote(noteId, rev);
      setNotes(prevNotes => prevNotes.filter(note => note._id !== noteId));
      if (selectedNote?._id === noteId) {
        setSelectedNote(null);
      }
    } catch (error) {
      console.error('Failed to delete note:', error);
      alert('Failed to delete note. Please try again.');
    }
  };

  const handleFileUpload = async (noteId: string, files: FileList) => {
    const note = notes.find(n => n._id === noteId);
    if (!note) return;

    try {
      for (const file of Array.from(files)) {
        await dataService.uploadAttachment(noteId, file);
      }
      
      // Reload the note to get updated attachments
      await loadNotes();
    } catch (error) {
      console.error('Failed to upload file:', error);
      alert('Failed to upload file. Please try again.');
    }
  };

  return (
    <div className="notes-app">
      {/* Header with sync status */}
      <header className="app-header">
        <h1>SyncNotes</h1>
        <SyncStatusComponent syncState={syncState} />
      </header>

      {/* Search bar */}
      <SearchComponent
        query={searchQuery}
        onChange={setSearchQuery}
        placeholder="Search notes..."
      />

      <div className="app-content">
        {/* Notes list sidebar */}
        <aside className="notes-sidebar">
          <button 
            className="create-note-btn"
            onClick={() => setIsCreating(true)}
          >
            + New Note
          </button>
          
          <NotesListComponent
            notes={notes}
            selectedNoteId={selectedNote?._id || null}
            onSelectNote={setSelectedNote}
            onDeleteNote={handleDeleteNote}
            loading={loading}
          />
        </aside>

        {/* Note editor */}
        <main className="note-editor-area">
          {isCreating ? (
            <NoteEditorComponent
              note={null}
              onSave={handleCreateNote}
              onCancel={() => setIsCreating(false)}
              onFileUpload={() => {}} // Can't upload files to non-existent notes
            />
          ) : selectedNote ? (
            <NoteEditorComponent
              note={selectedNote}
              onSave={handleUpdateNote}
              onCancel={() => setSelectedNote(null)}
              onFileUpload={(files) => handleFileUpload(selectedNote._id, files)}
            />
          ) : (
            <div className="no-note-selected">
              <p>Select a note to start editing, or create a new one.</p>
            </div>
          )}
        </main>
      </div>
    </div>
  );
};
```

```typescript
// apps/mobile-web/src/components/SyncStatus.tsx
import React from 'react';
import { SyncState } from '../types';

interface SyncStatusProps {
  syncState: SyncState;
}

export const SyncStatusComponent: React.FC<SyncStatusProps> = ({ syncState }) => {
  const getStatusIcon = () => {
    if (!syncState.isOnline) {
      return '📴'; // Offline
    }
    if (syncState.syncInProgress) {
      return '🔄'; // Syncing
    }
    if (syncState.pendingChanges > 0) {
      return '⏳'; // Pending changes
    }
    if (syncState.conflicts.length > 0) {
      return '⚠️'; // Conflicts
    }
    return '✅'; // All synced
  };

  const getStatusText = () => {
    if (!syncState.isOnline) {
      return `Offline - ${syncState.pendingChanges} changes pending`;
    }
    if (syncState.syncInProgress) {
      return 'Syncing...';
    }
    if (syncState.pendingChanges > 0) {
      return `${syncState.pendingChanges} changes pending sync`;
    }
    if (syncState.conflicts.length > 0) {
      return `${syncState.conflicts.length} conflicts need resolution`;
    }
    return `Synced ${syncState.lastSync ? new Date(syncState.lastSync).toLocaleTimeString() : 'recently'}`;
  };

  return (
    <div className={`sync-status ${!syncState.isOnline ? 'offline' : 'online'}`}>
      <span className="status-icon">{getStatusIcon()}</span>
      <span className="status-text">{getStatusText()}</span>
      
      {syncState.conflicts.length > 0 && (
        <button 
          className="resolve-conflicts-btn"
          onClick={() => {
            // Open conflict resolution dialog
            console.log('Open conflict resolution for:', syncState.conflicts);
          }}
        >
          Resolve
        </button>
      )}
    </div>
  );
};
```

## 🔧 **Phase 4: Performance Testing & Optimization**

### **4.1 Load Testing Examples**

```javascript
// examples/performance-tests/load-test-notes-api.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');

export const options = {
  stages: [
    { duration: '2m', target: 20 },   // Ramp up to 20 users over 2 minutes
    { duration: '5m', target: 20 },   // Stay at 20 users for 5 minutes
    { duration: '2m', target: 50 },   // Ramp up to 50 users
    { duration: '5m', target: 50 },   // Stay at 50 users for 5 minutes
    { duration: '2m', target: 100 },  // Ramp up to 100 users
    { duration: '5m', target: 100 },  // Stay at 100 users
    { duration: '2m', target: 0 },    // Ramp down to 0 users
  ],
  thresholds: {
    http_req_duration: ['p(90)<1500'], // 90% of requests must complete below 1.5s
    http_req_failed: ['rate<0.1'],     // Error rate must be below 10%
    errors: ['rate<0.1'],
  },
};

const BASE_URL = 'http://localhost:4000/api';
const AUTH_TOKEN = 'your-test-jwt-token';

export function setup() {
  // Create test namespace and return setup data
  const setupResponse = http.post(`${BASE_URL}/test-setup`, {
    namespace_type: 'load_test',
    user_count: 100
  }, {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${AUTH_TOKEN}`
    }
  });
  
  return { 
    namespaceId: JSON.parse(setupResponse.body).namespace_id 
  };
}

export default function(data) {
  const namespaceId = data.namespaceId;
  const userId = `user-${__VU}`; // Virtual User ID
  
  // Test 1: Create a note
  const createNotePayload = JSON.stringify({
    note: {
      title: `Load test note ${__VU}-${__ITER}`,
      content: `This is a load test note created by virtual user ${__VU} in iteration ${__ITER}. It contains some sample content to test the system under load.`,
      tags: ['load-test', `user-${__VU}`, 'performance']
    }
  });

  let createResponse = http.post(`${BASE_URL}/notes`, createNotePayload, {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${AUTH_TOKEN}`,
      'X-Namespace-ID': namespaceId,
      'X-User-ID': userId
    }
  });

  let createSuccess = check(createResponse, {
    'note created successfully': (resp) => resp.status === 201,
    'note has correct title': (resp) => {
      try {
        const note = JSON.parse(resp.body).data;
        return note.title.includes(`Load test note ${__VU}-${__ITER}`);
      } catch {
        return false;
      }
    },
    'create response time < 1s': (resp) => resp.timings.duration < 1000,
  });

  errorRate.add(!createSuccess);

  if (!createSuccess) {
    console.log(`Create note failed for VU ${__VU}, iteration ${__ITER}`);
    return;
  }

  const noteId = JSON.parse(createResponse.body).data.id;

  // Test 2: Get notes list
  let listResponse = http.get(`${BASE_URL}/notes?limit=20`, {
    headers: {
      'Authorization': `Bearer ${AUTH_TOKEN}`,
      'X-Namespace-ID': namespaceId,
      'X-User-ID': userId
    }
  });

  let listSuccess = check(listResponse, {
    'notes list retrieved': (resp) => resp.status === 200,
    'list contains notes': (resp) => {
      try {
        const data = JSON.parse(resp.body).data;
        return Array.isArray(data) && data.length > 0;
      } catch {
        return false;
      }
    },
    'list response time < 500ms': (resp) => resp.timings.duration < 500,
  });

  errorRate.add(!listSuccess);

  // Test 3: Update the note
  const updatePayload = JSON.stringify({
    note: {
      title: `Updated load test note ${__VU}-${__ITER}`,
      content: `This note was updated during load testing. User ${__VU}, iteration ${__ITER}.`,
      tags: ['load-test', 'updated', `user-${__VU}`]
    }
  });

  let updateResponse = http.put(`${BASE_URL}/notes/${noteId}`, updatePayload, {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${AUTH_TOKEN}`,
      'X-Namespace-ID': namespaceId,
      'X-User-ID': userId
    }
  });

  let updateSuccess = check(updateResponse, {
    'note updated successfully': (resp) => resp.status === 200,
    'update response time < 1s': (resp) => resp.timings.duration < 1000,
  });

  errorRate.add(!updateSuccess);

  // Test 4: Search notes
  let searchResponse = http.get(`${BASE_URL}/notes?search=load test`, {
    headers: {
      'Authorization': `Bearer ${AUTH_TOKEN}`,
      'X-Namespace-ID': namespaceId,
      'X-User-ID': userId
    }
  });

  let searchSuccess = check(searchResponse, {
    'search completed': (resp) => resp.status === 200,
    'search response time < 800ms': (resp) => resp.timings.duration < 800,
  });

  errorRate.add(!searchSuccess);

  // Test 5: File upload simulation (every 10th iteration)
  if (__ITER % 10 === 0) {
    const fileContent = 'fake-file-content-for-load-testing';
    const uploadPayload = {
      file: http.file(fileContent, 'test-file.txt', 'text/plain'),
      note_id: noteId
    };

    let uploadResponse = http.post(`${BASE_URL}/upload`, uploadPayload, {
      headers: {
        'Authorization': `Bearer ${AUTH_TOKEN}`,
        'X-Namespace-ID': namespaceId,
        'X-User-ID': userId
      }
    });

    let uploadSuccess = check(uploadResponse, {
      'file uploaded successfully': (resp) => resp.status === 200,
      'upload response time < 3s': (resp) => resp.timings.duration < 3000,
    });

    errorRate.add(!uploadSuccess);
  }

  // Realistic user behavior - pause between actions
  sleep(Math.random() * 2 + 1); // Sleep 1-3 seconds
}

export function teardown(data) {
  // Cleanup test namespace
  http.delete(`${BASE_URL}/test-cleanup/${data.namespaceId}`, {
    headers: {
      'Authorization': `Bearer ${AUTH_TOKEN}`
    }
  });
}
```

### **4.2 Database Performance Monitoring**

```elixir
# apps/backend-api/lib/syncnotes/telemetry/performance_monitor.ex
defmodule SyncNotes.Telemetry.PerformanceMonitor do
  @moduledoc """
  Monitors and reports on application performance metrics
  """
  use GenServer
  
  alias SyncNotes.Telemetry.Metrics
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Attach telemetry handlers
    :telemetry.attach_many(
      "performance-monitor",
      [
        [:couchdb, :query, :stop],
        [:postgres, :query, :stop],
        [:s3, :upload, :stop],
        [:phoenix, :endpoint, :stop]
      ],
      &handle_event/4,
      %{}
    )
    
    # Schedule periodic performance reports
    :timer.send_interval(60_000, self(), :generate_report)
    
    {:ok, %{metrics: %{}, last_report: DateTime.utc_now()}}
  end

  def handle_event([:couchdb, :query, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    
    # Track CouchDB query performance
    Metrics.record_histogram("couchdb_query_duration_ms", duration_ms, %{
      database: metadata.database,
      operation: metadata.operation
    })
    
    # Alert on slow queries
    if duration_ms > 1000 do
      Logger.warn("Slow CouchDB query detected", 
        duration_ms: duration_ms,
        database: metadata.database,
        operation: metadata.operation
      )
    end
  end

  def handle_event([:postgres, :query, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    
    Metrics.record_histogram("postgres_query_duration_ms", duration_ms, %{
      source: metadata.source,
      result: metadata.result
    })
    
    # Track query count and types
    Metrics.increment_counter("postgres_queries_total", %{
      source: metadata.source
    })
  end

  def handle_event([:s3, :upload, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    
    Metrics.record_histogram("s3_upload_duration_ms", duration_ms, %{
      bucket: metadata.bucket,
      content_type: metadata.content_type
    })
    
    Metrics.record_histogram("s3_upload_size_bytes", metadata.file_size, %{
      content_type: metadata.content_type
    })
  end

  def handle_event([:phoenix, :endpoint, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    
    # Track HTTP request performance
    Metrics.record_histogram("http_request_duration_ms", duration_ms, %{
      method: metadata.method,
      route: metadata.route,
      status: metadata.status
    })
    
    # Track request counts by status
    Metrics.increment_counter("http_requests_total", %{
      method: metadata.method,
      status: metadata.status
    })
    
    # Alert on slow endpoints
    if duration_ms > 2000 do
      Logger.warn("Slow HTTP request detected",
        duration_ms: duration_ms,
        method: metadata.method,
        route: metadata.route,
        status: metadata.status
      )
    end
  end

  def handle_info(:generate_report, state) do
    # Generate and log performance report
    report = generate_performance_report()
    Logger.info("Performance Report", report: report)
    
    # Send to external monitoring if configured
    if Application.get_env(:syncnotes, :external_monitoring_enabled) do
      send_to_external_monitoring(report)
    end
    
    {:noreply, %{state | last_report: DateTime.utc_now()}}
  end

  defp generate_performance_report do
    now = DateTime.utc_now()
    
    %{
      timestamp: now,
      couchdb: %{
        avg_query_time: Metrics.get_avg("couchdb_query_duration_ms"),
        slow_queries: Metrics.get_count("couchdb_slow_queries"),
        total_queries: Metrics.get_count("couchdb_queries_total")
      },
      postgres: %{
        avg_query_time: Metrics.get_avg("postgres_query_duration_ms"),
        total_queries: Metrics.get_count("postgres_queries_total")
      },
      s3: %{
        avg_upload_time: Metrics.get_avg("s3_upload_duration_ms"),
        avg_file_size: Metrics.get_avg("s3_upload_size_bytes"),
        total_uploads: Metrics.get_count("s3_uploads_total")
      },
      http: %{
        avg_response_time: Metrics.get_avg("http_request_duration_ms"),
        total_requests: Metrics.get_count("http_requests_total"),
        error_rate: calculate_error_rate()
      },
      memory_usage: :erlang.memory(:total),
      process_count: length(Process.list())
    }
  end

  defp calculate_error_rate do
    total = Metrics.get_count("http_requests_total")
    errors = Metrics.get_count("http_requests_total", %{status: "5xx"})
    
    if total > 0, do: errors / total * 100, else: 0
  end

  defp send_to_external_monitoring(report) do
    # Send to DataDog, New Relic, or other monitoring service
    # Implementation would depend on your monitoring provider
    Task.start(fn ->
      case HTTPoison.post(
        Application.get_env(:syncnotes, :monitoring_webhook_url),
        Jason.encode!(report),
        [{"Content-Type", "application/json"}]
      ) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("Failed to send monitoring data: #{inspect(reason)}")
      end
    end)
  end
end
```

### **4.3 Frontend Performance Testing**

```javascript
// examples/performance-tests/frontend-performance.js
// Lighthouse CI configuration for automated performance testing

const lighthouse = require('lighthouse');
const chromeLauncher = require('chrome-launcher');
const fs = require('fs');

async function runLighthouseTest(url, options = {}) {
  const chrome = await chromeLauncher.launch({chromeFlags: ['--headless']});
  const flags = {
    logLevel: 'info',
    output: 'json',
    onlyCategories: ['performance', 'accessibility', 'best-practices'],
    port: chrome.port,
    ...options
  };

  const runnerResult = await lighthouse(url, flags);
  await chrome.kill();

  return runnerResult;
}

async function testAppPerformance() {
  const scenarios = [
    {
      name: 'App Load',
      url: 'http://localhost:3000',
      thresholds: {
        performance: 90,
        'first-contentful-paint': 1500,
        'largest-contentful-paint': 2500,
        'cumulative-layout-shift': 0.1
      }
    },
    {
      name: 'Notes List',
      url: 'http://localhost:3000/notes',
      thresholds: {
        performance: 85,
        'first-contentful-paint': 1000,
        'time-to-interactive': 3000
      }
    },
    {
      name: 'Note Editor',
      url: 'http://localhost:3000/notes/new',
      thresholds: {
        performance: 80,
        'first-contentful-paint': 1200,
        'time-to-interactive': 3500
      }
    }
  ];

  const results = [];

  for (const scenario of scenarios) {
    console.log(`Running performance test: ${scenario.name}`);
    
    const result = await runLighthouseTest(scenario.url);
    const report = result.report;
    const audits = JSON.parse(report).audits;
    
    const performanceScore = JSON.parse(report).categories.performance.score * 100;
    const fcp = audits['first-contentful-paint'].numericValue;
    const lcp = audits['largest-contentful-paint'].numericValue;
    const cls = audits['cumulative-layout-shift'].numericValue;
    const tti = audits['time-to-interactive'].numericValue;

    const testResult = {
      scenario: scenario.name,
      url: scenario.url,
      scores: {
        performance: performanceScore,
        'first-contentful-paint': fcp,
        'largest-contentful-paint': lcp,
        'cumulative-layout-shift': cls,
        'time-to-interactive': tti
      },
      passed: checkThresholds(scenario.thresholds, {
        performance: performanceScore,
        'first-contentful-paint': fcp,
        'largest-contentful-paint': lcp,
        'cumulative-layout-shift': cls,
        'time-to-interactive': tti
      })
    };

    results.push(testResult);
    
    console.log(`${scenario.name} - Performance Score: ${performanceScore}`);
    console.log(`${scenario.name} - FCP: ${fcp}ms`);
    console.log(`${scenario.name} - LCP: ${lcp}ms`);
    console.log(`${scenario.name} - CLS: ${cls}`);
    console.log(`${scenario.name} - TTI: ${tti}ms`);
    console.log(`${scenario.name} - Passed: ${testResult.passed ? 'YES' : 'NO'}\n`);
  }

  // Generate report
  const report = {
    timestamp: new Date().toISOString(),
    results: results,
    summary: {
      totalTests: results.length,
      passedTests: results.filter(r => r.passed).length,
      averagePerformanceScore: results.reduce((sum, r) => sum + r.scores.performance, 0) / results.length
    }
  };

  // Save report
  fs.writeFileSync('performance-report.json', JSON.stringify(report, null, 2));
  
  console.log('\n=== Performance Test Summary ===');
  console.log(`Total Tests: ${report.summary.totalTests}`);
  console.log(`Passed Tests: ${report.summary.passedTests}`);
  console.log(`Average Performance Score: ${report.summary.averagePerformanceScore.toFixed(1)}`);
  
  return report;
}

function checkThresholds(thresholds, scores) {
  for (const [metric, threshold] of Object.entries(thresholds)) {
    const score = scores[metric];
    
    // For performance scores, higher is better
    if (metric === 'performance') {
      if (score < threshold) return false;
    }
    // For timing metrics, lower is better
    else if (metric.includes('paint') || metric.includes('interactive')) {
      if (score > threshold) return false;
    }
    // For CLS, lower is better
    else if (metric === 'cumulative-layout-shift') {
      if (score > threshold) return false;
    }
  }
  
  return true;
}

// Run the performance tests
testAppPerformance().catch(console.error);
```

## 🚀 **Phase 5: Production Deployment Examples**

### **5.1 Docker Production Setup**

```dockerfile
# apps/backend-api/Dockerfile.prod
FROM elixir:1.15-alpine as build

# Install build dependencies
RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set production environment
ENV MIX_ENV=prod

# Copy mix files
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy source
COPY . .

# Compile and build release
RUN mix compile
RUN mix assets.deploy
RUN mix release

# Production image
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app

# Create non-root user
RUN addgroup -g 1000 syncnotes && \
    adduser -D -s /bin/sh -u 1000 -G syncnotes syncnotes

# Copy release from build stage
COPY --from=build --chown=syncnotes:syncnotes /app/_build/prod/rel/syncnotes ./

# Set up directories with proper permissions
RUN mkdir -p /app/tmp /app/logs && \
    chown -R syncnotes:syncnotes /app

USER syncnotes

EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

CMD ["./bin/syncnotes", "start"]
```

```dockerfile
# apps/mobile-web/Dockerfile.prod
FROM node:18-alpine as build

WORKDIR /app

# Copy package files
COPY package*.json ./
RUN npm ci --only=production

# Copy source
COPY . .

# Build the app
ENV NODE_ENV=production
RUN npm run build

# Production image with nginx
FROM nginx:alpine

# Copy built app
COPY --from=build /app/dist /usr/share/nginx/html

# Copy nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Copy SSL certificates if available
COPY ssl/ /etc/nginx/ssl/

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
```

### **5.2 Kubernetes Production Deployment**

```yaml
# infrastructure/kubernetes/production/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: syncnotes-prod
  labels:
    name: syncnotes-prod
    environment: production

---
# infrastructure/kubernetes/production/backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: syncnotes-backend
  namespace: syncnotes-prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: syncnotes-backend
  template:
    metadata:
      labels:
        app: syncnotes-backend
        version: v1
    spec:
      containers:
      - name: backend
        image: gcr.io/your-project/syncnotes-backend:latest
        ports:
        - containerPort: 4000
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: syncnotes-secrets
              key: database-url
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: syncnotes-secrets
              key: secret-key-base
        - name: S3_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: s3-credentials
              key: access-key-id
        - name: S3_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: s3-credentials
              key: secret-access-key
        - name: COUCHDB_URL
          valueFrom:
            secretKeyRef:
              name: couchdb-credentials
              key: url
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: syncnotes-backend-service
  namespace: syncnotes-prod
spec:
  selector:
    app: syncnotes-backend
  ports:
  - protocol: TCP
    port: 80
    targetPort: 4000
  type: ClusterIP

---
# infrastructure/kubernetes/production/frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: syncnotes-frontend
  namespace: syncnotes-prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: syncnotes-frontend
  template:
    metadata:
      labels:
        app: syncnotes-frontend
        version: v1
    spec:
      containers:
      - name: frontend
        image: gcr.io/your-project/syncnotes-frontend:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: syncnotes-frontend-service
  namespace: syncnotes-prod
spec:
  selector:
    app: syncnotes-frontend
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP

---
# infrastructure/kubernetes/production/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: syncnotes-ingress
  namespace: syncnotes-prod
  annotations:
    kubernetes.io/ingress.class: "nginx"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
  - hosts:
    - syncnotes.yourdomain.com
    - api.syncnotes.yourdomain.com
    secretName: syncnotes-tls
  rules:
  - host: syncnotes.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: syncnotes-frontend-service
            port:
              number: 80
  - host: api.syncnotes.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: syncnotes-backend-service
            port:
              number: 80

---
# infrastructure/kubernetes/production/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: syncnotes-backend-hpa
  namespace: syncnotes-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: syncnotes-backend
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### **5.3 Production Monitoring Setup**

```yaml
# infrastructure/monitoring/prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: syncnotes-prod
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    rule_files:
      - "syncnotes_alerts.yml"

    scrape_configs:
      - job_name: 'syncnotes-backend'
        static_configs:
          - targets: ['syncnotes-backend-service:80']
        metrics_path: /metrics
        scrape_interval: 15s

      - job_name: 'couchdb'
        static_configs:
          - targets: ['couchdb-service:5984']
        metrics_path: /_node/_local/_prometheus
        scrape_interval: 30s

      - job_name: 'postgres'
        static_configs:
          - targets: ['postgres-exporter:9187']
        scrape_interval: 30s

      - job_name: 'nginx'
        static_configs:
          - targets: ['nginx-exporter:9113']
        scrape_interval: 15s

    alertmanager_configs:
      - static_configs:
          - targets: ['alertmanager:9093']

  syncnotes_alerts.yml: |
    groups:
    - name: syncnotes
      rules:
      - alert: HighErrorRate
        expr: (rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate detected"
          description: "Error rate is {{ $value }}% for {{ $labels.job }}"

      - alert: HighResponseTime
        expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High response time detected"
          description: "95th percentile response time is {{ $value }}s"

      - alert: DatabaseConnectionsHigh
        expr: postgres_connections_active / postgres_connections_max > 0.8
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Database connections are high"
          description: "Active connections: {{ $value }}"

      - alert: CouchDBReplicationLag
        expr: couchdb_replication_lag_seconds > 300
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CouchDB replication lag is high"
          description: "Replication lag: {{ $value }} seconds"
```

## 📚 **Phase 6: Confidence-Building Examples**

### **6.1 Progressive Feature Examples**

```markdown
# examples/progressive-features/README.md

# Progressive Feature Development Examples

This directory contains a series of progressive examples that build upon each other,
helping junior developers gain confidence in building complex features.

## Learning Path

### Level 1: Basic CRUD (2-3 days)
- Create/Read/Update/Delete notes
- Basic validation and error handling
- Simple UI components

### Level 2: File Handling (2-3 days)
- Upload attachments to notes
- Display different file types
- Handle upload errors and progress

### Level 3: Search & Filtering (3-4 days)
- Full-text search across notes
- Tag-based filtering
- Advanced search with multiple criteria

### Level 4: Offline Support (4-5 days)
- Cache notes for offline access
- Queue operations when offline
- Sync when connection restored

### Level 5: Real-time Collaboration (5-7 days)
- Share notes with other users
- Real-time editing with conflict resolution
- User presence indicators

### Level 6: Performance Optimization (3-5 days)
- Implement lazy loading
- Optimize database queries
- Add caching layers

### Level 7: Production Deployment (4-6 days)
- Set up monitoring and logging
- Configure auto-scaling
- Implement health checks
```

```javascript
// examples/progressive-features/level-1-basic-crud/NoteCRUD.js
/**
 * Level 1 Example: Basic CRUD Operations
 * 
 * Learning Objectives:
 * - Understand REST API patterns
 * - Handle async operations with promises
 * - Implement basic error handling
 * - Use React hooks for state management
 */

import React, { useState, useEffect } from 'react';

const API_BASE = '/api';

export function NoteCRUD() {
  const [notes, setNotes] = useState([]);
  const [selectedNote, setSelectedNote] = useState(null);
  const [isEditing, setIsEditing] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Load notes on component mount
  useEffect(() => {
    loadNotes();
  }, []);

  const loadNotes = async () => {
    setLoading(true);
    setError(null);
    
    try {
      const response = await fetch(`${API_BASE}/notes`);
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      
      const data = await response.json();
      setNotes(data.data);
    } catch (err) {
      setError(`Failed to load notes: ${err.message}`);
      console.error('Load notes error:', err);
    } finally {
      setLoading(false);
    }
  };

  const createNote = async (noteData) => {
    setLoading(true);
    setError(null);
    
    try {
      const response = await fetch(`${API_BASE}/notes`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ note: noteData })
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to create note');
      }

      const data = await response.json();
      const newNote = data.data;
      
      // Update local state
      setNotes(prevNotes => [newNote, ...prevNotes]);
      setSelectedNote(newNote);
      setIsEditing(false);
      
      console.log('Note created successfully:', newNote);
    } catch (err) {
      setError(`Failed to create note: ${err.message}`);
      console.error('Create note error:', err);
    } finally {
      setLoading(false);
    }
  };

  const updateNote = async (noteId, noteData) => {
    setLoading(true);
    setError(null);
    
    try {
      const response = await fetch(`${API_BASE}/notes/${noteId}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ note: noteData })
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to update note');
      }

      const data = await response.json();
      const updatedNote = data.data;
      
      // Update local state
      setNotes(prevNotes => 
        prevNotes.map(note => 
          note._id === noteId ? updatedNote : note
        )
      );
      setSelectedNote(updatedNote);
      setIsEditing(false);
      
      console.log('Note updated successfully:', updatedNote);
    } catch (err) {
      setError(`Failed to update note: ${err.message}`);
      console.error('Update note error:', err);
    } finally {
      setLoading(false);
    }
  };

  const deleteNote = async (noteId) => {
    if (!window.confirm('Are you sure you want to delete this note?')) {
      return;
    }
    
    setLoading(true);
    setError(null);
    
    try {
      const response = await fetch(`${API_BASE}/notes/${noteId}`, {
        method: 'DELETE'
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to delete note');
      }
      
      // Update local state
      setNotes(prevNotes => prevNotes.filter(note => note._id !== noteId));
      
      if (selectedNote && selectedNote._id === noteId) {
        setSelectedNote(null);
      }
      
      console.log('Note deleted successfully');
    } catch (err) {
      setError(`Failed to delete note: ${err.message}`);
      console.error('Delete note error:', err);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="note-crud-container">
      {/* Error Display */}
      {error && (
        <div className="error-banner">
          <strong>Error:</strong> {error}
          <button onClick={() => setError(null)}>×</button>
        </div>
      )}

      {/* Loading Indicator */}
      {loading && (
        <div className="loading-indicator">
          <div className="spinner"></div>
          <span>Loading...</span>
        </div>
      )}

      {/* Notes List */}
      <div className="notes-list">
        <div className="notes-header">
          <h2>Your Notes ({notes.length})</h2>
          <button 
            className="create-button"
            onClick={() => setIsEditing(true)}
            disabled={loading}
          >
            + New Note
          </button>
        </div>

        {notes.length === 0 && !loading ? (
          <div className="empty-state">
            <p>No notes yet. Create your first note!</p>
          </div>
        ) : (
          <div className="notes-grid">
            {notes.map(note => (
              <NoteCard 
                key={note._id}
                note={note}
                isSelected={selectedNote && selectedNote._id === note._id}
                onSelect={() => setSelectedNote(note)}
                onEdit={() => {
                  setSelectedNote(note);
                  setIsEditing(true);
                }}
                onDelete={() => deleteNote(note._id)}
              />
            ))}
          </div>
        )}
      </div>

      {/* Note Editor Modal */}
      {isEditing && (
        <NoteEditor
          note={selectedNote}
          onSave={(noteData) => {
            if (selectedNote) {
              updateNote(selectedNote._id, noteData);
            } else {
              createNote(noteData);
            }
          }}
          onCancel={() => {
            setIsEditing(false);
            setSelectedNote(null);
          }}
        />
      )}
    </div>
  );
}

function NoteCard({ note, isSelected, onSelect, onEdit, onDelete }) {
  const formatDate = (dateString) => {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  };

  return (
    <div 
      className={`note-card ${isSelected ? 'selected' : ''}`}
      onClick={onSelect}
    >
      <h3 className="note-title">{note.title || 'Untitled'}</h3>
      <p className="note-preview">
        {note.content ? note.content.substring(0, 100) + '...' : 'No content'}
      </p>
      
      <div className="note-meta">
        <span className="note-date">
          {formatDate(note.updated_at || note.created_at)}
        </span>
        
        {note.tags && note.tags.length > 0 && (
          <div className="note-tags">
            {note.tags.slice(0, 3).map(tag => (
              <span key={tag} className="tag">{tag}</span>
            ))}
            {note.tags.length > 3 && (
              <span className="tag-more">+{note.tags.length - 3}</span>
            )}
          </div>
        )}
      </div>

      <div className="note-actions">
        <button 
          className="edit-button"
          onClick={(e) => {
            e.stopPropagation();
            onEdit();
          }}
        >
          Edit
        </button>
        <button 
          className="delete-button"
          onClick={(e) => {
            e.stopPropagation();
            onDelete();
          }}
        >
          Delete
        </button>
      </div>
    </div>
  );
}

function NoteEditor({ note, onSave, onCancel }) {
  const [formData, setFormData] = useState({
    title: note?.title || '',
    content: note?.content || '',
    tags: note?.tags?.join(', ') || ''
  });
  const [errors, setErrors] = useState({});

  const validateForm = () => {
    const newErrors = {};
    
    if (!formData.title.trim()) {
      newErrors.title = 'Title is required';
    }
    
    if (!formData.content.trim()) {
      newErrors.content = 'Content is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = (e) => {
    e.preventDefault();
    
    if (!validateForm()) {
      return;
    }

    const noteData = {
      title: formData.title.trim(),
      content: formData.content.trim(),
      tags: formData.tags
        .split(',')
        .map(tag => tag.trim())
        .filter(tag => tag.length > 0)
    };

    onSave(noteData);
  };

  const handleInputChange = (field, value) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    
    // Clear error when user starts typing
    if (errors[field]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
    }
  };

  return (
    <div className="modal-overlay">
      <div className="note-editor-modal">
        <div className="modal-header">
          <h2>{note ? 'Edit Note' : 'Create New Note'}</h2>
          <button className="close-button" onClick={onCancel}>×</button>
        </div>

        <form onSubmit={handleSubmit} className="note-form">
          <div className="form-group">
            <label htmlFor="title">Title *</label>
            <input
              id="title"
              type="text"
              value={formData.title}
              onChange={(e) => handleInputChange('title', e.target.value)}
              className={errors.title ? 'error' : ''}
              placeholder="Enter note title..."
            />
            {errors.title && (
              <span className="error-message">{errors.title}</span>
            )}
          </div>

          <div className="form-group">
            <label htmlFor="content">Content *</label>
            <textarea
              id="content"
              value={formData.content}
              onChange={(e) => handleInputChange('content', e.target.value)}
              className={errors.content ? 'error' : ''}
              placeholder="Write your note content..."
              rows={10}
            />
            {errors.content && (
              <span className="error-message">{errors.content}</span>
            )}
          </div>

          <div className="form-group">
            <label htmlFor="tags">Tags</label>
            <input
              id="tags"
              type="text"
              value={formData.tags}
              onChange={(e) => handleInputChange('tags', e.target.value)}
              placeholder="Enter tags separated by commas..."
            />
            <small className="help-text">
              Separate multiple tags with commas (e.g., work, important, ideas)
            </small>
          </div>

          <div className="form-actions">
            <button type="button" onClick={onCancel} className="cancel-button">
              Cancel
            </button>
            <button type="submit" className="save-button">
              {note ? 'Update Note' : 'Create Note'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
```

### **6.2 Testing Confidence Builders**

```javascript
// examples/progressive-features/level-1-basic-crud/NoteCRUD.test.js
/**
 * Level 1 Testing Example: Basic CRUD Tests
 * 
 * Learning Objectives:
 * - Write unit tests for React components
 * - Mock API calls for testing
 * - Test user interactions and state changes
 * - Understand test structure and assertions
 */

import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import '@testing-library/jest-dom';
import { NoteCRUD } from './NoteCRUD';

// Mock fetch globally
global.fetch = jest.fn();

describe('NoteCRUD Component', () => {
  beforeEach(() => {
    // Clear all mocks before each test
    fetch.mockClear();
  });

  describe('Loading Notes', () => {
    test('displays loading indicator while fetching notes', async () => {
      // Mock a delayed API response
      fetch.mockImplementation(() => 
        new Promise(resolve => setTimeout(() => resolve({
          ok: true,
          json: () => Promise.resolve({ data: [] })
        }), 100))
      );

      render(<NoteCRUD />);

      // Check that loading indicator appears
      expect(screen.getByText(/loading/i)).toBeInTheDocument();
      expect(screen.getByRole('generic', { name: /spinner/i })).toBeInTheDocument();

      // Wait for loading to complete
      await waitFor(() => {
        expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
      });
    });

    test('displays notes after successful fetch', async () => {
      const mockNotes = [
        {
          _id: '1',
          title: 'Test Note 1',
          content: 'This is test content 1',
          created_at: '2023-01-01T00:00:00Z',
          tags: ['test']
        },
        {
          _id: '2',
          title: 'Test Note 2', 
          content: 'This is test content 2',
          created_at: '2023-01-02T00:00:00Z',
          tags: ['test', 'example']
        }
      ];

      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: mockNotes })
      });

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.getByText('Test Note 1')).toBeInTheDocument();
        expect(screen.getByText('Test Note 2')).toBeInTheDocument();
      });

      expect(screen.getByText('Your Notes (2)')).toBeInTheDocument();
    });

    test('displays error message when fetch fails', async () => {
      fetch.mockRejectedValueOnce(new Error('Network error'));

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.getByText(/failed to load notes/i)).toBeInTheDocument();
      });
    });

    test('displays empty state when no notes exist', async () => {
      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: [] })
      });

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.getByText(/no notes yet/i)).toBeInTheDocument();
        expect(screen.getByText(/create your first note/i)).toBeInTheDocument();
      });
    });
  });

  describe('Creating Notes', () => {
    beforeEach(async () => {
      // Setup with empty notes list
      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: [] })
      });

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
      });
    });

    test('opens note editor when create button is clicked', async () => {
      const user = userEvent.setup();

      await user.click(screen.getByText('+ New Note'));

      expect(screen.getByText('Create New Note')).toBeInTheDocument();
      expect(screen.getByLabelText(/title/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/content/i)).toBeInTheDocument();
    });

    test('validates required fields', async () => {
      const user = userEvent.setup();

      await user.click(screen.getByText('+ New Note'));
      await user.click(screen.getByText('Create Note'));

      expect(screen.getByText('Title is required')).toBeInTheDocument();
      expect(screen.getByText('Content is required')).toBeInTheDocument();
    });

    test('creates note with valid data', async () => {
      const user = userEvent.setup();
      const newNote = {
        _id: '3',
        title: 'New Test Note',
        content: 'New test content',
        created_at: '2023-01-03T00:00:00Z',
        tags: ['new']
      };

      // Mock successful creation
      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: newNote })
      });

      await user.click(screen.getByText('+ New Note'));

      // Fill in the form
      await user.type(screen.getByLabelText(/title/i), 'New Test Note');
      await user.type(screen.getByLabelText(/content/i), 'New test content');
      await user.type(screen.getByLabelText(/tags/i), 'new');

      await user.click(screen.getByText('Create Note'));

      await waitFor(() => {
        expect(screen.getByText('New Test Note')).toBeInTheDocument();
      });

      // Verify API was called correctly
      expect(fetch).toHaveBeenCalledWith('/api/notes', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          note: {
            title: 'New Test Note',
            content: 'New test content',
            tags: ['new']
          }
        })
      });
    });

    test('handles creation errors gracefully', async () => {
      const user = userEvent.setup();

      fetch.mockResolvedValueOnce({
        ok: false,
        json: () => Promise.resolve({ error: 'Validation failed' })
      });

      await user.click(screen.getByText('+ New Note'));
      await user.type(screen.getByLabelText(/title/i), 'Test');
      await user.type(screen.getByLabelText(/content/i), 'Test');
      await user.click(screen.getByText('Create Note'));

      await waitFor(() => {
        expect(screen.getByText(/failed to create note/i)).toBeInTheDocument();
      });
    });
  });

  describe('Updating Notes', () => {
    const existingNote = {
      _id: '1',
      title: 'Existing Note',
      content: 'Existing content',
      created_at: '2023-01-01T00:00:00Z',
      tags: ['existing']
    };

    beforeEach(async () => {
      // Setup with one existing note
      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: [existingNote] })
      });

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.getByText('Existing Note')).toBeInTheDocument();
      });
    });

    test('opens editor with existing note data', async () => {
      const user = userEvent.setup();

      await user.click(screen.getByText('Edit'));

      expect(screen.getByText('Edit Note')).toBeInTheDocument();
      expect(screen.getByDisplayValue('Existing Note')).toBeInTheDocument();
      expect(screen.getByDisplayValue('Existing content')).toBeInTheDocument();
      expect(screen.getByDisplayValue('existing')).toBeInTheDocument();
    });

    test('updates note successfully', async () => {
      const user = userEvent.setup();
      const updatedNote = {
        ...existingNote,
        title: 'Updated Note',
        content: 'Updated content'
      };

      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: updatedNote })
      });

      await user.click(screen.getByText('Edit'));

      // Clear and update title
      await user.clear(screen.getByDisplayValue('Existing Note'));
      await user.type(screen.getByLabelText(/title/i), 'Updated Note');

      // Clear and update content
      await user.clear(screen.getByDisplayValue('Existing content'));
      await user.type(screen.getByLabelText(/content/i), 'Updated content');

      await user.click(screen.getByText('Update Note'));

      await waitFor(() => {
        expect(screen.getByText('Updated Note')).toBeInTheDocument();
      });

      // Verify API was called correctly
      expect(fetch).toHaveBeenCalledWith('/api/notes/1', {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          note: {
            title: 'Updated Note',
            content: 'Updated content',
            tags: ['existing']
          }
        })
      });
    });
  });

  describe('Deleting Notes', () => {
    const existingNote = {
      _id: '1',
      title: 'Note to Delete',
      content: 'Content to delete',
      created_at: '2023-01-01T00:00:00Z',
      tags: []
    };

    beforeEach(async () => {
      // Setup with one existing note
      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ data: [existingNote] })
      });

      // Mock window.confirm
      global.confirm = jest.fn();

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.getByText('Note to Delete')).toBeInTheDocument();
      });
    });

    test('shows confirmation dialog before deleting', async () => {
      const user = userEvent.setup();
      global.confirm.mockReturnValue(false); // User cancels

      await user.click(screen.getByText('Delete'));

      expect(global.confirm).toHaveBeenCalledWith(
        'Are you sure you want to delete this note?'
      );

      // Note should still be there since user cancelled
      expect(screen.getByText('Note to Delete')).toBeInTheDocument();
    });

    test('deletes note when confirmed', async () => {
      const user = userEvent.setup();
      global.confirm.mockReturnValue(true); // User confirms

      fetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({})
      });

      await user.click(screen.getByText('Delete'));

      await waitFor(() => {
        expect(screen.queryByText('Note to Delete')).not.toBeInTheDocument();
      });

      // Verify API was called correctly
      expect(fetch).toHaveBeenCalledWith('/api/notes/1', {
        method: 'DELETE'
      });
    });

    test('handles deletion errors', async () => {
      const user = userEvent.setup();
      global.confirm.mockReturnValue(true);

      fetch.mockResolvedValueOnce({
        ok: false,
        json: () => Promise.resolve({ error: 'Cannot delete note' })
      });

      await user.click(screen.getByText('Delete'));

      await waitFor(() => {
        expect(screen.getByText(/failed to delete note/i)).toBeInTheDocument();
      });

      // Note should still be there since deletion failed
      expect(screen.getByText('Note to Delete')).toBeInTheDocument();
    });
  });

  describe('Error Handling', () => {
    test('can dismiss error messages', async () => {
      fetch.mockRejectedValueOnce(new Error('Test error'));

      render(<NoteCRUD />);

      await waitFor(() => {
        expect(screen.getByText(/failed to load notes/i)).toBeInTheDocument();
      });

      const user = userEvent.setup();
      await user.click(screen.getByText('×'));

      expect(screen.queryByText(/failed to load notes/i)).not.toBeInTheDocument();
    });
  });
});

// Integration test example
describe('NoteCRUD Integration Tests', () => {
  test('complete user workflow: create, edit, delete', async () => {
    const user = userEvent.setup();

    // Mock initial load (empty)
    fetch.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ data: [] })
    });

    render(<NoteCRUD />);

    await waitFor(() => {
      expect(screen.getByText(/no notes yet/i)).toBeInTheDocument();
    });

    // Step 1: Create a note
    const newNote = {
      _id: 'new-1',
      title: 'Integration Test Note',
      content: 'This is an integration test',
      created_at: '2023-01-01T00:00:00Z',
      tags: ['test', 'integration']
    };

    fetch.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ data: newNote })
    });

    await user.click(screen.getByText('+ New Note'));
    await user.type(screen.getByLabelText(/title/i), 'Integration Test Note');
    await user.type(screen.getByLabelText(/content/i), 'This is an integration test');
    await user.type(screen.getByLabelText(/tags/i), 'test, integration');
    await user.click(screen.getByText('Create Note'));

    await waitFor(() => {
      expect(screen.getByText('Integration Test Note')).toBeInTheDocument();
    });

    // Step 2: Edit the note
    const updatedNote = {
      ...newNote,
      title: 'Updated Integration Test',
      content: 'This note was updated'
    };

    fetch.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ data: updatedNote })
    });

    await user.click(screen.getByText('Edit'));
    await user.clear(screen.getByDisplayValue('Integration Test Note'));
    await user.type(screen.getByLabelText(/title/i), 'Updated Integration Test');
    await user.clear(screen.getByDisplayValue('This is an integration test'));
    await user.type(screen.getByLabelText(/content/i), 'This note was updated');
    await user.click(screen.getByText('Update Note'));

    await waitFor(() => {
      expect(screen.getByText('Updated Integration Test')).toBeInTheDocument();
    });

    // Step 3: Delete the note
    global.confirm = jest.fn(() => true);
    fetch.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({})
    });

    await user.click(screen.getByText('Delete'));

    await waitFor(() => {
      expect(screen.queryByText('Updated Integration Test')).not.toBeInTheDocument();
      expect(screen.getByText(/no notes yet/i)).toBeInTheDocument();
    });

    // Verify all API calls were made correctly
    expect(fetch).toHaveBeenCalledTimes(4); // Initial load + create + update + delete
  });
});
```

This advanced development guide provides junior developers with:

1. **Complete project structure** with namespacing and data layer architecture
2. **Comprehensive testing frameworks** for building confidence through validation
3. **Progressive examples** that build complexity gradually
4. **Production-ready deployment** examples with monitoring
5. **Performance testing** tools and optimization techniques
6. **Real-world application example** with offline/online sync, P2P sharing, and multimedia support

The guide emphasizes hands-on learning with practical examples, comprehensive testing, and production deployment experience to build developer confidence and skills.

