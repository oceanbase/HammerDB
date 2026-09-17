# OceanBase TPROC-C quick start

1. Copy the parameter template: `cp oceanbase.env.example oceanbase.env`.
2. Edit `oceanbase.env` with the OceanBase connection and test size.
3. Build and verify the schema: `./build.sh`.
4. Run the benchmark: `./run.sh`.

The scripts locate `hammerdbcli` from the HammerDB tree automatically. Logs and
HammerDB JSON result artifacts are written to `results/`.

