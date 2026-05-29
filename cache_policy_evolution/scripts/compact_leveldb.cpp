// compact_leveldb — force a major compaction of a LevelDB at $1.
//
// Background: LevelDB lays its keys across SST files at multiple levels.
// The exact layout (file count, level distribution, file numbering) depends
// on how many compaction passes have run historically — two DBs with
// identical content can have very different on-disk shapes. Read amp is
// dominated by that shape: a flatter, fully-compacted DB walks fewer SSTs
// per get. Across a multi-worker calibration this shows up as wildly
// different throughput numbers from "the same" DB.
//
// Calling DB::CompactRange(nullptr, nullptr) forces all keys through to
// the bottom level, producing a canonical, deterministic shape regardless
// of history. Idempotent — re-running compacts whatever's left, which
// for an already-compacted DB is essentially nothing.
//
// Usage: compact_leveldb <db_path>
//   exit 0 on success; nonzero with a one-line diagnostic on stderr otherwise.

#include <iostream>
#include <leveldb/db.h>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: " << (argc > 0 ? argv[0] : "compact_leveldb")
                  << " <db_path>\n";
        return 2;
    }
    leveldb::Options opts;
    opts.create_if_missing = false;
    leveldb::DB* db = nullptr;
    leveldb::Status s = leveldb::DB::Open(opts, argv[1], &db);
    if (!s.ok()) {
        std::cerr << "open failed: " << s.ToString() << "\n";
        return 1;
    }
    std::cerr << "compacting " << argv[1] << " (full key range)..." << std::endl;
    db->CompactRange(nullptr, nullptr);
    std::cerr << "compaction complete." << std::endl;
    delete db;
    return 0;
}
