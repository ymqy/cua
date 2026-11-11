// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Linux adapters for encrypted Computer History.

use cua_driver_core::history::{
    ApplicationIdentity, ApplicationIdentityProvider, HistoryError, HistoryHealthCategory,
    HistoryKey, KeyProvider,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use zeroize::Zeroizing;

#[derive(Default)]
pub struct LinuxSecretServiceKeyProvider {
    inner: cua_driver_core::history_keyring::KeyringKeyProvider,
}

impl LinuxSecretServiceKeyProvider {
    pub fn shared() -> Arc<Self> {
        Arc::new(Self {
            inner: cua_driver_core::history_keyring::KeyringKeyProvider,
        })
    }

    fn fallback_key_dir() -> PathBuf {
        if let Ok(dir) = std::env::var("CUA_DRIVER_HISTORY_KEY_DIR") {
            return PathBuf::from(dir);
        }
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        home.join(".cua-driver").join("history_keys")
    }

    fn fallback_key_path(namespace: &str) -> PathBuf {
        Self::fallback_key_dir().join(format!("{namespace}.key"))
    }

    fn read_file_key(path: &Path) -> Result<Zeroizing<Vec<u8>>, HistoryError> {
        let bytes =
            fs::read(path).map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
        if bytes.len() != 32 {
            return Err(HistoryError::new(HistoryHealthCategory::KeyCorrupt));
        }
        Ok(Zeroizing::new(bytes))
    }

    fn write_file_key(path: &Path, bytes: &[u8]) -> Result<(), HistoryError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
            }
        }
        let temp_path = path.with_extension("tmp");
        let mut options = fs::OpenOptions::new();
        options.create(true).write(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        use std::io::Write;
        let mut file = options
            .open(&temp_path)
            .map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
        file.write_all(bytes)
            .map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
        file.sync_data()
            .map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
        fs::rename(temp_path, path)
            .map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
        Ok(())
    }
}

impl KeyProvider for LinuxSecretServiceKeyProvider {
    fn load_or_create(&self, namespace: &str) -> Result<HistoryKey, HistoryError> {
        match self.inner.load_or_create(namespace) {
            Ok(key) => Ok(key),
            Err(_) => {
                let path = Self::fallback_key_path(namespace);
                if path.is_file() {
                    let bytes = Self::read_file_key(&path)?;
                    return Ok(HistoryKey {
                        reference: format!("file:{}", path.display()),
                        epoch: 0,
                        bytes,
                    });
                }
                let mut bytes = Zeroizing::new(vec![0_u8; 32]);
                getrandom::fill(&mut bytes)
                    .map_err(|_| HistoryError::new(HistoryHealthCategory::KeyUnavailable))?;
                Self::write_file_key(&path, &bytes)?;
                Ok(HistoryKey {
                    reference: format!("file:{}", path.display()),
                    epoch: 0,
                    bytes,
                })
            }
        }
    }

    fn load(&self, namespace: &str, reference: &str) -> Result<HistoryKey, HistoryError> {
        if let Some(path_str) = reference.strip_prefix("file:") {
            let path = PathBuf::from(path_str);
            let bytes = Self::read_file_key(&path)?;
            return Ok(HistoryKey {
                reference: reference.to_owned(),
                epoch: 0,
                bytes,
            });
        }
        match self.inner.load(namespace, reference) {
            Ok(key) => Ok(key),
            Err(_) => {
                let path = Self::fallback_key_path(namespace);
                if path.is_file() {
                    let bytes = Self::read_file_key(&path)?;
                    return Ok(HistoryKey {
                        reference: format!("file:{}", path.display()),
                        epoch: 0,
                        bytes,
                    });
                }
                Err(HistoryError::new(HistoryHealthCategory::KeyUnavailable))
            }
        }
    }

    fn references(&self, namespace: &str) -> Result<Vec<String>, HistoryError> {
        let mut refs = self.inner.references(namespace).unwrap_or_default();
        let path = Self::fallback_key_path(namespace);
        if path.is_file() {
            let file_ref = format!("file:{}", path.display());
            if !refs.contains(&file_ref) {
                refs.push(file_ref);
            }
        }
        Ok(refs)
    }

    fn destroy(&self, namespace: &str, reference: &str) -> Result<(), HistoryError> {
        let _ = self.inner.destroy(namespace, reference);
        if let Some(path_str) = reference.strip_prefix("file:") {
            let path = PathBuf::from(path_str);
            let _ = fs::remove_file(path);
        } else {
            let path = Self::fallback_key_path(namespace);
            if path.is_file() {
                let _ = fs::remove_file(path);
            }
        }
        Ok(())
    }
}

#[derive(Default)]
pub struct LinuxApplicationIdentityProvider;

#[derive(Clone, Copy)]
enum WindowAppNameProvenance {
    StableAppId,
    Ambiguous,
}

fn stable_window_app_name(
    app_name: Option<String>,
    provenance: WindowAppNameProvenance,
) -> Option<String> {
    match provenance {
        WindowAppNameProvenance::StableAppId => app_name.filter(|name| !name.trim().is_empty()),
        WindowAppNameProvenance::Ambiguous => None,
    }
}

fn application_identity_from_stable_sources(
    process_name: String,
    platform_id: Option<String>,
) -> Option<ApplicationIdentity> {
    let process_name = (!process_name.trim().is_empty()).then_some(process_name);
    let bundle_id = platform_id.or_else(|| process_name.clone());
    (bundle_id.is_some() || process_name.is_some()).then_some(ApplicationIdentity {
        bundle_id,
        display_name: process_name,
    })
}

impl ApplicationIdentityProvider for LinuxApplicationIdentityProvider {
    fn resolve(&self, pid: i64, _window_id: Option<u64>) -> Option<ApplicationIdentity> {
        let pid = u32::try_from(pid).ok()?;
        let process = crate::proc_fs::list_processes()
            .into_iter()
            .find(|process| process.pid == pid)?;
        let platform_id = if crate::wayland::is_wayland() {
            // Wayland's shared WindowInfo cannot distinguish a native app ID
            // from the shell-helper fallback that copies the window title.
            // Do not enumerate or persist that ambiguous value in history.
            stable_window_app_name(None, WindowAppNameProvenance::Ambiguous)
        } else {
            stable_window_app_name(
                crate::x11::list_windows(Some(pid))
                    .into_iter()
                    .find_map(|window| {
                        (!window.app_name.trim().is_empty()).then_some(window.app_name)
                    }),
                WindowAppNameProvenance::StableAppId,
            )
        };
        application_identity_from_stable_sources(process.name, platform_id)
    }
}

pub fn application_identity_provider() -> Arc<dyn ApplicationIdentityProvider> {
    Arc::new(LinuxApplicationIdentityProvider)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_process_identity_is_resolvable_without_titles_or_paths() {
        let identity = LinuxApplicationIdentityProvider
            .resolve(i64::from(std::process::id()), None)
            .expect("current process identity");
        assert!(identity.bundle_id.is_some() || identity.display_name.is_some());
    }

    #[test]
    fn wayland_title_fallback_is_not_stored_as_application_identity() {
        let title = "Confidential roadmap - Web Browser".to_owned();
        let platform_id =
            stable_window_app_name(Some(title.clone()), WindowAppNameProvenance::Ambiguous);
        let identity = application_identity_from_stable_sources("browser".to_owned(), platform_id)
            .expect("process-derived identity");

        assert_eq!(identity.bundle_id.as_deref(), Some("browser"));
        assert_eq!(identity.display_name.as_deref(), Some("browser"));
        assert_ne!(identity.bundle_id.as_deref(), Some(title.as_str()));
        assert_ne!(identity.display_name.as_deref(), Some(title.as_str()));
    }
}
