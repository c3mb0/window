use duckdb::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{self, Read, Write};

#[derive(Debug, Deserialize, Serialize)]
struct Event {
    id: String,
    session_id: String,
    revision: i64,
    commit_order: i64,
    kind: String,
    observed_at: i64,
    schema_version: i64,
    payload: String,
    digest: String,
}

fn request(conn: &mut Connection, value: Value) -> Result<Value, Box<dyn std::error::Error>> {
    match value["op"].as_str().ok_or("missing operation")? {
        "identity" => {
            let expected = value["archive_id"]
                .as_str()
                .ok_or("missing archive identity")?;
            let existing: Option<String> =
                conn.query_row("SELECT archive_id FROM archive_meta", [], |row| row.get(0))?;
            match existing {
                Some(id) if id == expected => (),
                None if value["allow_create"] == true => {
                    conn.execute("UPDATE archive_meta SET archive_id = ?", params![expected])?;
                }
                _ => {
                    return Err(
                        "archive identity mismatch or previously bound archive missing".into(),
                    );
                }
            }
            Ok(json!({"archive_id": expected}))
        }
        "append" => {
            let events: Vec<Event> = serde_json::from_value(value["events"].clone())?;
            if events.len() > 250 {
                return Err("batch too large".into());
            }
            let transaction = conn.transaction()?;
            for event in &events {
                if event.schema_version != 1 {
                    return Err("unsupported event schema".into());
                }
                let mut statement = transaction.prepare("SELECT session_id, revision, commit_order, kind, observed_at, schema_version, payload, digest FROM session_events WHERE id = ?")?;
                let mut rows = statement.query(params![event.id])?;
                if let Some(row) = rows.next()? {
                    let existing = Event {
                        id: event.id.clone(),
                        session_id: row.get(0)?,
                        revision: row.get(1)?,
                        commit_order: row.get(2)?,
                        kind: row.get(3)?,
                        observed_at: row.get(4)?,
                        schema_version: row.get(5)?,
                        payload: row.get(6)?,
                        digest: row.get(7)?,
                    };
                    if serde_json::to_value(existing)? != serde_json::to_value(event)? {
                        return Err("event identity conflict".into());
                    }
                } else {
                    transaction.execute(
                        "INSERT INTO session_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        params![
                            event.id,
                            event.session_id,
                            event.revision,
                            event.commit_order,
                            event.kind,
                            event.observed_at,
                            event.schema_version,
                            event.payload,
                            event.digest
                        ],
                    )?;
                }
            }
            if cfg!(debug_assertions)
                && std::env::var("WINDOW_ARCHIVE_TEST_FAULT").as_deref() == Ok("before_commit")
            {
                eprintln!("FAULT_BEFORE_COMMIT");
                loop {
                    std::thread::park();
                }
            }
            transaction.commit()?;
            Ok(json!({"ids": events.iter().map(|e| &e.id).collect::<Vec<_>>()}))
        }
        "timeline" => {
            let id = value["session_id"].as_str().ok_or("missing session id")?;
            let mut statement = conn.prepare("SELECT id, revision, kind, observed_at, payload FROM session_events WHERE session_id = ? ORDER BY revision DESC LIMIT 250")?;
            let rows = statement.query_map(params![id], |row| Ok(json!({"id": row.get::<_, String>(0)?, "revision": row.get::<_, i64>(1)?, "kind": row.get::<_, String>(2)?, "observed_at": row.get::<_, i64>(3)?, "payload": row.get::<_, String>(4)?})))?;
            Ok(json!({"events": rows.collect::<Result<Vec<_>, _>>()?}))
        }
        "status" => Ok(
            json!({"events": conn.query_row("SELECT count(*) FROM session_events", [], |r| r.get::<_, i64>(0))?}),
        ),
        "checkpoint" | "shutdown" => {
            conn.execute_batch("CHECKPOINT")?;
            Ok(json!({}))
        }
        _ => Err("unsupported operation".into()),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let file = std::env::args().nth(1).ok_or("archive path required")?;
    let mut conn = Connection::open(file)?;
    conn.execute_batch("SET threads = 2; SET memory_limit = '256MB'; SET enable_external_access = false;
        CREATE TABLE IF NOT EXISTS archive_meta (version INTEGER PRIMARY KEY, archive_id VARCHAR);
        INSERT INTO archive_meta SELECT 1, NULL WHERE NOT EXISTS (SELECT 1 FROM archive_meta);
        CREATE TABLE IF NOT EXISTS session_events (id VARCHAR PRIMARY KEY, session_id VARCHAR NOT NULL, revision BIGINT NOT NULL, commit_order BIGINT NOT NULL, kind VARCHAR NOT NULL, observed_at BIGINT NOT NULL, schema_version INTEGER NOT NULL, payload VARCHAR NOT NULL, digest VARCHAR NOT NULL, UNIQUE(session_id, revision));")?;
    let version: i32 = conn.query_row("SELECT version FROM archive_meta", [], |row| row.get(0))?;
    if version != 1 {
        return Err("unsupported archive schema".into());
    }
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut header = [0u8; 4];
        match input.read_exact(&mut header) {
            Ok(()) => (),
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e.into()),
        }
        let size = u32::from_be_bytes(header) as usize;
        if size > 4 * 1024 * 1024 {
            return Err("request too large".into());
        }
        let mut bytes = vec![0; size];
        input.read_exact(&mut bytes)?;
        let shutdown = serde_json::from_slice::<Value>(&bytes)
            .is_ok_and(|value| value["op"] == "shutdown");
        let result = serde_json::from_slice(&bytes)
            .map_err(|e| e.into())
            .and_then(|value| request(&mut conn, value));
        let should_exit = shutdown && result.is_ok();
        let response = match result {
            Ok(data) => json!({"ok": data}),
            Err(error) => json!({"error": error.to_string()}),
        };
        let response = serde_json::to_vec(&response)?;
        output.write_all(&(response.len() as u32).to_be_bytes())?;
        output.write_all(&response)?;
        output.flush()?;
        if should_exit { break; }
    }
    Ok(())
}
