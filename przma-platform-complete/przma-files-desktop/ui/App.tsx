import React, { useState, useEffect, useRef, useCallback, DragEvent } from 'react';

// ─── Tauri global type ───────────────────────────────────────────────────────
declare global {
  interface Window {
    __TAURI__?: {
      core: {
        invoke: (cmd: string, args?: any) => Promise<any>;
      };
    };
  }
}

// ─── Types ───────────────────────────────────────────────────────────────────
interface FileRecord {
  id: string;
  name: string;
  size_bytes: number;
  mime_type?: string;
  created_at?: string;
  content_cas?: string;
  przma_uri?: string;
}

interface Toast {
  id: number;
  text: string;
  type: 'success' | 'error' | 'info';
  exiting?: boolean;
}

type Page = 'mine' | 'commons' | 'circle' | 'settings';

// ─── Helpers ─────────────────────────────────────────────────────────────────
const FILE_ICONS: Record<string, string> = {
  'image': '🖼️',
  'video': '🎬',
  'audio': '🎵',
  'application/pdf': '📕',
  'application/zip': '📦',
  'application/x-rar': '📦',
  'text': '📝',
  'font': '🔤',
};

function getFileIcon(name: string, mime?: string): string {
  if (mime) {
    if (FILE_ICONS[mime]) return FILE_ICONS[mime];
    const category = mime.split('/')[0];
    if (FILE_ICONS[category]) return FILE_ICONS[category];
  }
  const ext = name.split('.').pop()?.toLowerCase() || '';
  const extMap: Record<string, string> = {
    pdf: '📕', doc: '📄', docx: '📄', xls: '📊', xlsx: '📊', ppt: '📑', pptx: '📑',
    png: '🖼️', jpg: '🖼️', jpeg: '🖼️', gif: '🖼️', svg: '🖼️', webp: '🖼️',
    mp4: '🎬', mov: '🎬', avi: '🎬', mkv: '🎬',
    mp3: '🎵', wav: '🎵', flac: '🎵', ogg: '🎵',
    zip: '📦', rar: '📦', '7z': '📦', tar: '📦', gz: '📦',
    js: '⚡', ts: '⚡', py: '🐍', rs: '🦀', go: '🐹',
    json: '📋', xml: '📋', csv: '📋', yaml: '📋', yml: '📋',
    md: '📝', txt: '📝', html: '🌐', css: '🎨',
  };
  return extMap[ext] || '📄';
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function formatDate(iso?: string): string {
  if (!iso) return '';
  try {
    const d = new Date(iso);
    return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
  } catch { return ''; }
}

let toastId = 0;

// ═════════════════════════════════════════════════════════════════════════════
// MAIN APP
// ═════════════════════════════════════════════════════════════════════════════

export default function App() {
  // ─── State ───────────────────────────────────────────────────────────────
  const [page, setPage] = useState<Page>('mine');
  const [theme, setTheme] = useState<'dark' | 'light'>(() =>
    (localStorage.getItem('przma_theme') as 'dark' | 'light') || 'dark'
  );
  const [isOnline, setIsOnline] = useState(navigator.onLine);
  const [did, setDid] = useState('did:web:alice.com');
  const [namespace, setNamespace] = useState(() =>
    localStorage.getItem('przmaSettings_ns') || 'did:web:alice.com'
  );
  const [circleDid, setCircleDid] = useState(() =>
    localStorage.getItem('przmaSettings_circle') || ''
  );

  const [files, setFiles] = useState<FileRecord[]>([]);
  const [isUploading, setIsUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState({ current: 0, total: 0, fileName: '' });
  const [dragOver, setDragOver] = useState(false);
  const [toasts, setToasts] = useState<Toast[]>([]);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const dragCounterRef = useRef(0);

  // ─── Theme ───────────────────────────────────────────────────────────────
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('przma_theme', theme);
  }, [theme]);

  // ─── Online/Offline ──────────────────────────────────────────────────────
  useEffect(() => {
    const goOnline = () => setIsOnline(true);
    const goOffline = () => {
      setIsOnline(false);
      // If on a sharing page, redirect to mine
      if (page === 'commons' || page === 'circle') {
        setPage('mine');
        addToast('Switched to Mine — you are offline', 'info');
      }
    };
    window.addEventListener('online', goOnline);
    window.addEventListener('offline', goOffline);
    return () => {
      window.removeEventListener('online', goOnline);
      window.removeEventListener('offline', goOffline);
    };
  }, [page]);

  // ─── Load DID from backend ───────────────────────────────────────────────
  useEffect(() => {
    if (window.__TAURI__) {
      window.__TAURI__.core.invoke('get_did').then((d: string) => {
        if (d) setDid(d);
      }).catch(() => {});
    }
  }, []);

  // ─── Load files when page changes ────────────────────────────────────────
  useEffect(() => {
    if (page !== 'settings') {
      loadFiles();
    }
  }, [page]);

  // ─── Toast helper ────────────────────────────────────────────────────────
  const addToast = useCallback((text: string, type: Toast['type']) => {
    const id = ++toastId;
    setToasts(prev => [...prev, { id, text, type }]);
    setTimeout(() => {
      setToasts(prev => prev.map(t => t.id === id ? { ...t, exiting: true } : t));
      setTimeout(() => {
        setToasts(prev => prev.filter(t => t.id !== id));
      }, 300);
    }, 4000);
  }, []);

  const dismissToast = useCallback((id: number) => {
    setToasts(prev => prev.map(t => t.id === id ? { ...t, exiting: true } : t));
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id));
    }, 300);
  }, []);

  // ─── Space resolver ──────────────────────────────────────────────────────
  const getSpace = useCallback((): string => {
    switch (page) {
      case 'mine': return 'core';
      case 'commons': return 'commons';
      case 'circle': return circleDid ? `circle:${circleDid}` : 'circle';
      default: return 'core';
    }
  }, [page, circleDid]);

  // ─── Load files ──────────────────────────────────────────────────────────
  const loadFiles = async () => {
    const space = getSpace();
    try {
      if (window.__TAURI__) {
        const data = await window.__TAURI__.core.invoke('list_files', { space });
        setFiles(data.files || []);
      }
    } catch (err) {
      const e = err as Error;
      addToast(`Failed to load files: ${e?.message || String(e)}`, 'error');
    }
  };

  // ─── Upload files ────────────────────────────────────────────────────────
  const uploadFiles = async (fileList: File[]) => {
    if (fileList.length === 0) return;

    const space = getSpace();
    setIsUploading(true);
    let successCount = 0;
    let errorCount = 0;

    for (let i = 0; i < fileList.length; i++) {
      const file = fileList[i];
      setUploadProgress({ current: i + 1, total: fileList.length, fileName: file.name });

      try {
        const arrayBuffer = await file.arrayBuffer();
        const bytes = new Uint8Array(arrayBuffer);

        // Base64 encode in chunks to avoid call-stack overflow
        let base64 = '';
        const chunkSize = 8192;
        for (let j = 0; j < bytes.length; j += chunkSize) {
          const chunk = bytes.subarray(j, j + chunkSize);
          base64 += String.fromCharCode(...Array.from(chunk));
        }
        base64 = btoa(base64);

        if (window.__TAURI__) {
          const result = await window.__TAURI__.core.invoke('upload_file', {
            fileName: file.name,
            filePath: '/',
            space,
            mimeType: file.type || 'application/octet-stream',
            content: base64,
          });
          if (result.success) successCount++;
        } else {
          throw new Error('Tauri API not available');
        }
      } catch (err) {
        errorCount++;
        const e = err as Error;
        console.error('Upload error:', e);
      }
    }

    setIsUploading(false);
    setUploadProgress({ current: 0, total: 0, fileName: '' });

    if (errorCount > 0) {
      addToast(`Uploaded ${successCount}/${fileList.length} — ${errorCount} failed`, 'error');
    } else {
      addToast(`Uploaded ${successCount} file${successCount > 1 ? 's' : ''} successfully`, 'success');
    }

    loadFiles();
  };

  // ─── Delete file ─────────────────────────────────────────────────────────
  const deleteFile = async (id: string, name: string) => {
    const space = getSpace();
    try {
      if (window.__TAURI__) {
        await window.__TAURI__.core.invoke('delete_file', { fileId: id, space });
        addToast(`Deleted "${name}"`, 'success');
        loadFiles();
      }
    } catch (err) {
      const e = err as Error;
      addToast(`Failed to delete: ${e?.message || String(e)}`, 'error');
    }
  };

  // ─── Save settings ──────────────────────────────────────────────────────
  const saveSettings = () => {
    localStorage.setItem('przmaSettings_ns', namespace);
    if (circleDid) localStorage.setItem('przmaSettings_circle', circleDid);
    addToast('Settings saved', 'success');
  };

  // ─── Drag & Drop handlers ───────────────────────────────────────────────
  const onDragEnter = (e: DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    dragCounterRef.current++;
    if (e.dataTransfer.items && e.dataTransfer.items.length > 0) {
      setDragOver(true);
    }
  };

  const onDragOver = (e: DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
  };

  const onDragLeave = (e: DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    dragCounterRef.current--;
    if (dragCounterRef.current === 0) {
      setDragOver(false);
    }
  };

  const onDrop = (e: DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    setDragOver(false);
    dragCounterRef.current = 0;
    const droppedFiles = Array.from(e.dataTransfer.files);
    if (droppedFiles.length > 0) {
      uploadFiles(droppedFiles);
    }
  };

  const onBrowseClick = () => {
    fileInputRef.current?.click();
  };

  const onFileInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files.length > 0) {
      uploadFiles(Array.from(e.target.files));
      e.target.value = '';
    }
  };

  // ─── Navigate helper ────────────────────────────────────────────────────
  const navigateTo = (target: Page) => {
    if ((target === 'commons' || target === 'circle') && !isOnline) return;
    setPage(target);
  };

  // ─── Page titles ─────────────────────────────────────────────────────────
  const pageConfig: Record<Page, { title: string; subtitle: string }> = {
    mine: { title: 'Mine', subtitle: 'Private · Offline-first · Encrypted at rest' },
    commons: { title: 'Public', subtitle: 'Public shared files · Available to everyone' },
    circle: { title: 'My Circle', subtitle: 'Group collaboration · Shared with your circle' },
    settings: { title: 'Settings', subtitle: 'Configure your identity and preferences' },
  };

  // ═══════════════════════════════════════════════════════════════════════════
  // RENDER
  // ═══════════════════════════════════════════════════════════════════════════
  return (
    <div className="app">
      {/* ── Offline Banner ────────────────────────────────────────────────── */}
      {!isOnline && (
        <div className="offline-banner">
          ⚡ You are offline — only Mine is available
        </div>
      )}

      {/* ── Top Bar ───────────────────────────────────────────────────────── */}
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark">P</div>
          <span>PRZMA</span>
        </div>

        <div className="topbar-right">
          <div className="did-chip">
            <div className="did-dot" />
            <span className="did-text">{did}</span>
          </div>
          <button
            className="icon-btn"
            onClick={() => setTheme(t => t === 'dark' ? 'light' : 'dark')}
            title={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
            id="theme-toggle"
          >
            {theme === 'dark' ? '☀️' : '🌙'}
          </button>
        </div>
      </header>

      {/* ── Body ──────────────────────────────────────────────────────────── */}
      <div className="body">
        {/* ── Sidebar ───────────────────────────────────────────────────── */}
        <nav className="sidebar">
          <div className="sidebar-label">Storage</div>

          <button
            id="nav-mine"
            className={`nav-item ${page === 'mine' ? 'active' : ''}`}
            onClick={() => navigateTo('mine')}
          >
            <span className="nav-label">
              <span className="nav-title">Mine</span>
              <span className="nav-sub">Private · Core</span>
            </span>
          </button>

          <div className="sidebar-label">Sharing</div>

          <button
            id="nav-commons"
            className={`nav-item ${page === 'commons' ? 'active' : ''} ${!isOnline ? 'disabled' : ''}`}
            onClick={() => navigateTo('commons')}
            {...(!isOnline ? { 'data-tooltip': 'Requires internet' } : {})}
          >
            <span className="nav-label">
              <span className="nav-title">Public</span>
              <span className="nav-sub">Shared · Open</span>
            </span>
          </button>

          <button
            id="nav-circle"
            className={`nav-item ${page === 'circle' ? 'active' : ''} ${!isOnline ? 'disabled' : ''}`}
            onClick={() => navigateTo('circle')}
            {...(!isOnline ? { 'data-tooltip': 'Requires internet' } : {})}
          >
            <span className="nav-label">
              <span className="nav-title">My Circle</span>
              <span className="nav-sub">Group · Collaborate</span>
            </span>
          </button>

          <div className="sidebar-divider" />

          <button
            id="nav-settings"
            className={`nav-item ${page === 'settings' ? 'active' : ''}`}
            onClick={() => navigateTo('settings')}
          >
            <span className="nav-label">
              <span className="nav-title">Settings</span>
              <span className="nav-sub">Identity · Prefs</span>
            </span>
          </button>

          {/* ── Sidebar Footer ───────────────────────────────────────── */}
          <div className="sidebar-footer">
            <span className={`status-dot ${isOnline ? 'online' : 'offline'}`} />
            <span className="status-text">{isOnline ? 'Online' : 'Offline'}</span>
          </div>
        </nav>

        {/* ── Content ───────────────────────────────────────────────────── */}
        <main className="content">
          <div className="content-head">
            <h1>{pageConfig[page].title}</h1>
            <p className="content-sub">{pageConfig[page].subtitle}</p>
          </div>

          {/* ── Circle DID Input (only on circle page) ─────────────── */}
          {page === 'circle' && (
            <div className="circle-input-row">
              <input
                type="text"
                value={circleDid}
                onChange={e => setCircleDid(e.target.value)}
                placeholder="Circle DID — e.g. did:web:family.przma.net"
              />
              <button
                className="btn-primary"
                onClick={() => {
                  if (circleDid) {
                    localStorage.setItem('przmaSettings_circle', circleDid);
                    loadFiles();
                    addToast('Circle DID saved', 'success');
                  }
                }}
              >
                Connect
              </button>
            </div>
          )}

          {/* ── Upload / Files (non-settings pages) ────────────────── */}
          {page !== 'settings' && (
            <>
              {/* Drag & Drop Zone */}
              <div
                id="dropzone"
                className={`dropzone ${dragOver ? 'drag-over' : ''} ${isUploading ? 'uploading' : ''}`}
                onDragEnter={onDragEnter}
                onDragOver={onDragOver}
                onDragLeave={onDragLeave}
                onDrop={onDrop}
                onClick={onBrowseClick}
              >
                <span className="dropzone-icon">
                  {isUploading ? '⏳' : dragOver ? '📥' : '☁️'}
                </span>
                <div className="dropzone-text">
                  {isUploading ? (
                    <span>Uploading <strong>{uploadProgress.fileName}</strong></span>
                  ) : (
                    <>
                      <span>Drop files here or <strong>click to browse</strong></span>
                    </>
                  )}
                </div>
                {!isUploading && (
                  <div className="dropzone-hint">
                    Supports any file type · Hold Ctrl to select multiple
                  </div>
                )}

                {isUploading && (
                  <div className="upload-progress">
                    <div className="progress-bar-track">
                      <div
                        className="progress-bar-fill"
                        style={{ width: `${(uploadProgress.current / uploadProgress.total) * 100}%` }}
                      />
                    </div>
                    <div className="progress-text">
                      {uploadProgress.current} / {uploadProgress.total} files
                    </div>
                  </div>
                )}

                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  className="hidden"
                  onChange={onFileInputChange}
                  id="fileInput"
                />
              </div>

              {/* File List */}
              <div className="files-head">
                <h2>
                  Files <span className="count-badge">{files.length}</span>
                </h2>
                <button className="ghost-btn" onClick={loadFiles}>
                  🔄 Refresh
                </button>
              </div>

              {files.length === 0 ? (
                <div className="empty">
                  <span className="empty-icon">📂</span>
                  <p>No files yet</p>
                  <span>Drop files above to get started</span>
                </div>
              ) : (
                <div className="file-grid">
                  {files.map((f, idx) => (
                    <div
                      className="file-card"
                      key={f.id}
                      style={{ animationDelay: `${idx * 40}ms` }}
                    >
                      <div className="file-thumb">
                        {getFileIcon(f.name, f.mime_type)}
                      </div>
                      <div className="file-meta">
                        <span className="file-name" title={f.name}>{f.name}</span>
                        <span className="file-sub">
                          {formatBytes(f.size_bytes)}
                          {f.created_at && (
                            <>
                              <span className="dot" />
                              {formatDate(f.created_at)}
                            </>
                          )}
                        </span>
                      </div>
                      <button
                        className="del-btn"
                        onClick={(e) => { e.stopPropagation(); deleteFile(f.id, f.name); }}
                        title="Delete file"
                      >
                        🗑️
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </>
          )}

          {/* ── Settings Page ──────────────────────────────────────────── */}
          {page === 'settings' && (
            <div className="settings-section">
              <div className="form-group">
                <label className="form-label">Namespace (DID)</label>
                <input
                  id="settings-namespace"
                  className="form-input"
                  type="text"
                  value={namespace}
                  onChange={e => setNamespace(e.target.value)}
                  placeholder="did:web:alice.com"
                />
              </div>

              <div className="form-group">
                <label className="form-label">Circle DID (optional)</label>
                <input
                  id="settings-circle"
                  className="form-input"
                  type="text"
                  value={circleDid}
                  onChange={e => setCircleDid(e.target.value)}
                  placeholder="did:web:family.przma.net"
                />
              </div>

              <div className="form-group">
                <label className="form-label">Appearance</label>
                <button
                  className="ghost-btn"
                  onClick={() => setTheme(t => t === 'dark' ? 'light' : 'dark')}
                >
                  {theme === 'dark' ? '☀️ Switch to Light' : '🌙 Switch to Dark'}
                </button>
              </div>

              <button className="btn-primary" onClick={saveSettings} id="save-settings">
                💾 Save Settings
              </button>
            </div>
          )}
        </main>
      </div>

      {/* ── Toast Container ──────────────────────────────────────────────── */}
      <div className="toast-container">
        {toasts.map(t => (
          <div key={t.id} className={`toast ${t.type} ${t.exiting ? 'exiting' : ''}`}>
            <span className="toast-icon">
              {t.type === 'success' ? '✅' : t.type === 'error' ? '❌' : 'ℹ️'}
            </span>
            <span className="toast-msg">{t.text}</span>
            <button className="toast-close" onClick={() => dismissToast(t.id)}>×</button>
          </div>
        ))}
      </div>
    </div>
  );
}