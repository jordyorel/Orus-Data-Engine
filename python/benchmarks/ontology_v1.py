import argparse
import json
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

from orus_ontology.performance import benchmark_materialization, benchmark_postgres
from orus_ontology.storage.postgres import PostgresStore

RUN_ID = UUID("dca43ce5-0fd8-5cbc-b9d7-8a2527f50fde")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=10_000)
    parser.add_argument("--batch-size", type=int, default=1_024)
    parser.add_argument("--postgres")
    arguments = parser.parse_args()
    observed_at = datetime(2026, 8, 15, 12, tzinfo=UTC)
    report: dict[str, object] = {
        "materialization": benchmark_materialization(
            arguments.engine,
            arguments.csv,
            rows=arguments.rows,
            batch_size=arguments.batch_size,
            run_id=RUN_ID,
            observed_at=observed_at,
        ).model_dump(mode="json")
    }
    if arguments.postgres:
        with PostgresStore(arguments.postgres, application_name="orus-ontology-benchmark") as store:
            report["postgres"] = benchmark_postgres(
                store,
                arguments.engine,
                arguments.csv,
                rows=arguments.rows,
                batch_size=arguments.batch_size,
                run_id=RUN_ID,
                observed_at=observed_at,
                customer_id="4962FDBE6BFEE6D",
            ).model_dump(mode="json")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
