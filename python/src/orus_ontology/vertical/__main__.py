"""Command-line import for the customer vertical."""

import argparse
import json
from datetime import datetime
from pathlib import Path
from uuid import UUID

from orus_ontology.storage.postgres import PostgresStore
from orus_ontology.vertical.importer import CustomerImporter


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m orus_ontology.vertical")
    parser.add_argument("csv", type=Path)
    parser.add_argument("--postgres", required=True)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--run-id", type=UUID, required=True)
    parser.add_argument("--observed-at", type=datetime.fromisoformat, required=True)
    parser.add_argument("--batch-size", type=int, default=1_024)
    parser.add_argument("--start-offset", type=int, default=0)
    parser.add_argument("--max-rows", type=int)
    parser.add_argument("--checkpoint", type=Path)
    arguments = parser.parse_args()
    with PostgresStore(arguments.postgres) as store:
        result = CustomerImporter(store, arguments.engine).run(
            arguments.csv,
            run_id=arguments.run_id,
            observed_at=arguments.observed_at,
            batch_size=arguments.batch_size,
            start_offset=arguments.start_offset,
            max_rows=arguments.max_rows,
            checkpoint_path=arguments.checkpoint,
        )
    print(json.dumps(result.model_dump(mode="json"), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
