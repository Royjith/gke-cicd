Web Security Scanner integration

Prerequisites
- Enable API: `websecurityscanner.googleapis.com`
- Cloud Build service account needs permissions: `roles/container.clusterViewer`, `roles/container.developer` (for cluster creds), `roles/securitycenter.findingsViewer` (optional), and permission to call Web Security Scanner API.
- Your services must be internet-accessible (LoadBalancer IP/hostname) for the scanner.

How it works
- After Cloud Deploy creates a release, Cloud Build runs `security/web_security_scanner.sh`.
- The script resolves external endpoints for the services you define, verifies reachability, creates/starts a scan, waits for completion, and optionally fails the build based on severity.

Configuration knobs (via env)
- `PROJECT_ID`: GCP project (auto-detected if not set)
- `REGION`: GKE cluster region (default `us-central1`)
- `CLUSTER`: GKE cluster name (default `autopilot-cluster-1`)
- `NAMESPACE`: Kubernetes namespace (default `default`)
- `SERVICES`: Comma-separated `name:port` list (default `my-service:8080,flask-service:8081`)
- `SCAN_DISPLAY_NAME`: Display name for scan config (default includes `${SHORT_SHA}`)
- `SCAN_FAIL_ON_SEVERITY`: `NONE|ANY|LOW|MEDIUM|HIGH` (default `NONE`)
- `SERVICE_READY_TIMEOUT_SECS`: Wait for LB endpoints (default `600`)
- `SCAN_TIMEOUT_SECS`: Wait for scan completion (default `3600`)

Local dry run
```bash
bash security/web_security_scanner.sh
```


