// Replacement for sui-rpc-api's build.rs that does NOT invoke `cargo metadata`.
//
// Upstream uses `cargo metadata --format-version=1` from the workspace root to
// discover where the `sui-rpc` crate lives so it can include its `vendored/proto`
// directory in the protoc include path. That breaks under cargo-vendor: the
// vendored crate has no surrounding workspace, so `cargo metadata` returns an
// empty document and the build script panics.
//
// Cargo-vendor places every git-sourced crate under `<vendor>/source-git-N/`,
// where N is per-(repo, rev). Crates that live in different source-gits than
// us still appear as siblings two levels up. Walk
// `CARGO_MANIFEST_DIR/../..` looking for `<source-git-N>/<package_name>-...`.

use std::ffi::OsStr;
use std::fs;
use std::path::PathBuf;
use walkdir::WalkDir;

fn find_dependency_proto_dir(package_name: &str, subpath: &str) -> PathBuf {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let crate_path = PathBuf::from(&crate_dir);
    let vendor_root = crate_path
        .parent()
        .and_then(|p| p.parent())
        .unwrap_or(&crate_path)
        .to_path_buf();

    let prefix = format!("{}-", package_name);

    // Search the immediate sibling first (same source-git as us), then every
    // other source-git-N peer.
    let mut search_roots: Vec<PathBuf> = Vec::new();
    if let Some(p) = crate_path.parent() {
        search_roots.push(p.to_path_buf());
    }
    if let Ok(entries) = fs::read_dir(&vendor_root) {
        for entry in entries.flatten() {
            if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                search_roots.push(entry.path());
            }
        }
    }

    for root in &search_roots {
        let Ok(entries) = fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with(&prefix) {
                let candidate = entry.path().join(subpath);
                if candidate.exists() {
                    return candidate;
                }
            }
        }
    }

    panic!(
        "no `{}*` package containing `{}` found under vendor root {:?}",
        prefix, subpath, vendor_root
    );
}

fn main() {
    let crate_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let sui_proto_dir = crate_dir.join("proto");
    let out_dir = crate_dir.join("src/proto/generated");

    let sui_rpc_proto_dir = find_dependency_proto_dir("sui-rpc", "vendored/proto");

    println!("cargo:rerun-if-changed={}", sui_proto_dir.display());
    println!("cargo:rerun-if-changed={}", sui_rpc_proto_dir.display());

    fs::create_dir_all(&out_dir).expect("create proto out dir");

    let proto_ext = OsStr::new("proto");
    let mut proto_files = vec![];
    for entry in WalkDir::new(&sui_proto_dir) {
        let entry = entry.unwrap();
        if entry.file_type().is_dir() {
            continue;
        }

        let path = entry.into_path();
        if path.extension() == Some(proto_ext) {
            proto_files.push(path)
        }
    }

    proto_files.sort();

    let file_descriptors = protox::compile(proto_files, [sui_proto_dir, sui_rpc_proto_dir])
        .expect("failed to compile proto files");

    tonic_prost_build::configure()
        .build_client(true)
        .build_server(true)
        .type_attribute(".", "#[non_exhaustive]")
        .extern_path(".sui.rpc.v2", "::sui_rpc::proto::sui::rpc::v2")
        .out_dir(&out_dir)
        .compile_fds(file_descriptors)
        .expect("compile event_service.proto");
}
