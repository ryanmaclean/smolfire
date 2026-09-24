# SPDX-License-Identifier: Apache-2.0
# openlineage-export.nu — project compact BOP/filesystem records to OpenLineage
#
# This exporter is intentionally a projection layer, not a state store. It reads
# compact internal records (JSON, one record or a list of records) that have
# already been derived from BOP run identity, filesystem-native version/history
# identity, and observed input/output mutations, then emits deterministic
# OpenLineage RunEvent JSON.
#
# Usage:
#   nu bin/openlineage-export.nu --from record.json
#   cat records.json | nu bin/openlineage-export.nu
#
# Supported lifecycle mapping:
#   pending -> running = START
#   running -> done    = COMPLETE
#   running -> failed  = FAIL

export const PROJECTION_SCHEMA_VERSION = "v1"
const TOOL_PRODUCER = "https://github.com/ryanmaclean/smolfire/blob/main/bin/openlineage-export.nu"
const RUN_EVENT_SCHEMA_URL = "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/RunEvent"
const PARENT_RUN_FACET_SCHEMA_URL = "https://openlineage.io/spec/facets/1-2-0/ParentRunFacet.json#/$defs/ParentRunFacet"
const JOB_DEPENDENCIES_FACET_SCHEMA_URL = "https://openlineage.io/spec/facets/1-0-1/JobDependenciesRunFacet.json#/$defs/JobDependenciesRunFacet"
const DATASET_VERSION_FACET_SCHEMA_URL = "https://openlineage.io/spec/facets/1-0-1/DatasetVersionDatasetFacet.json#/$defs/DatasetVersionDatasetFacet"
const SMOLFIRE_BOP_RUN_FACET_SCHEMA_URL = "https://github.com/ryanmaclean/smolfire/blob/main/docs/OPENLINEAGE-PROJECTION.md#smolfireboprunfacet"
const SMOLFIRE_BOP_JOB_FACET_SCHEMA_URL = "https://github.com/ryanmaclean/smolfire/blob/main/docs/OPENLINEAGE-PROJECTION.md#smolfirebopjobfacet"
const SMOLFIRE_FILESYSTEM_VERSION_FACET_SCHEMA_URL = "https://github.com/ryanmaclean/smolfire/blob/main/docs/OPENLINEAGE-PROJECTION.md#smolfirefilesystemversiondatasetfacet"

const EVENT_TYPE_MAP = {
    "pending->running": "START"
    "running->done": "COMPLETE"
    "running->failed": "FAIL"
}

const OPENLINEAGE_EVENT_TYPES = ["START", "RUNNING", "COMPLETE", "ABORT", "FAIL", "OTHER"]

# Small helper to fail with a readable message.
def fail [msg: string] {
    error make {msg: $msg}
}

# Build the required OpenLineage base facet fields.
def base-facet [schema_url: string] {
    {
        _producer: $TOOL_PRODUCER
        _schemaURL: $schema_url
    }
}

# Return a record without the listed keys.
def record-without [rec: record, drop: list<string>] {
    $rec
    | transpose key value
    | where {|row| not ($row.key in $drop)}
    | reduce -f {} {|row, acc| $acc | insert $row.key $row.value}
}

# Validate the top-level record schema version.
def require-schema-version [doc: record] {
    let schema = $doc | get schema_version? | default ""
    if $schema != $PROJECTION_SCHEMA_VERSION {
        fail $"unsupported schema_version '($schema)' (want ($PROJECTION_SCHEMA_VERSION))"
    }
}

# Resolve the OpenLineage event type either explicitly or from the BOP state edge.
export def infer-event-type [doc: record] {
    let explicit = $doc | get event_type? | default ""
    if ($explicit | str length) > 0 {
        if $explicit in $OPENLINEAGE_EVENT_TYPES {
            return $explicit
        }
        fail $"unsupported event_type '($explicit)'"
    }

    let run = $doc | get run? | default {}
    let state_from = $run | get state_from? | default ""
    let state_to = $run | get state_to? | default ""
    let key = $"($state_from)->($state_to)"
    let event_type = $EVENT_TYPE_MAP | get -o $key
    if $event_type == null {
        fail $"unsupported BOP lifecycle edge '($key)'"
    }
    $event_type
}

# Build the custom job facet that keeps BOP card/template identity explicit.
def build-job-facets [job: record] {
    let card = $job | get card? | default ""
    let template = $job | get template? | default ""
    if ($card | str length) == 0 and ($template | str length) == 0 {
        return {}
    }

    let facet = (
        base-facet $SMOLFIRE_BOP_JOB_FACET_SCHEMA_URL
        | merge {
            card: (if ($card | str length) > 0 { $card } else { $job.name })
            template: (if ($template | str length) > 0 { $template } else { $job.name })
        }
    )
    {smolfireBop: $facet}
}

# Build the ParentRunFacet when a parent run/job was supplied.
def build-parent-run-facet [parent: record] {
    let parent_run_id = $parent | get run_id? | default ""
    let parent_job = $parent | get job? | default {}
    let parent_ns = $parent_job | get namespace? | default ""
    let parent_name = $parent_job | get name? | default ""
    if ($parent_run_id | str length) == 0 or ($parent_ns | str length) == 0 or ($parent_name | str length) == 0 {
        fail "parent facet requires parent.run_id and parent.job.{namespace,name}"
    }

    mut facet = (
        base-facet $PARENT_RUN_FACET_SCHEMA_URL
        | merge {
            run: {runId: $parent_run_id}
            job: {
                namespace: $parent_ns
                name: $parent_name
            }
        }
    )

    let root = $parent | get root? | default null
    if $root != null {
        let root_run_id = $root | get run_id? | default ""
        let root_job = $root | get job? | default {}
        let root_ns = $root_job | get namespace? | default ""
        let root_name = $root_job | get name? | default ""
        if ($root_run_id | str length) == 0 or ($root_ns | str length) == 0 or ($root_name | str length) == 0 {
            fail "parent.root requires root.run_id and root.job.{namespace,name}"
        }
        $facet = $facet | merge {
            root: {
                run: {runId: $root_run_id}
                job: {
                    namespace: $root_ns
                    name: $root_name
                }
            }
        }
    }

    {parent: $facet}
}

# Build the JobDependenciesRunFacet from upstream BOP job/run dependencies.
def build-job-dependencies-facet [dependencies: list<record>] {
    if ($dependencies | is-empty) {
        return {}
    }

    let upstream = (
        $dependencies
        | each {|dep|
            let dep_job = $dep | get job? | default {}
            let dep_ns = $dep_job | get namespace? | default ""
            let dep_name = $dep_job | get name? | default ""
            if ($dep_ns | str length) == 0 or ($dep_name | str length) == 0 {
                fail "each dependency requires dependency.job.{namespace,name}"
            }

            mut row = {
                job: {
                    namespace: $dep_ns
                    name: $dep_name
                }
            }

            let dep_run_id = $dep | get run_id? | default ""
            if ($dep_run_id | str length) > 0 {
                $row = $row | merge {run: {runId: $dep_run_id}}
            }

            for key in [dependency_type sequence_trigger_rule status_trigger_rule] {
                let value = $dep | get -o $key
                if $value != null and ($value | into string | str length) > 0 {
                    $row = $row | insert $key $value
                }
            }

            $row
        }
        | sort-by job.namespace job.name
    )

    {
        jobDependencies: (
            base-facet $JOB_DEPENDENCIES_FACET_SCHEMA_URL
            | merge {upstream: $upstream}
        )
    }
}

# Build dataset facets. The standard `version` facet carries the canonical
# datasetVersion string; the custom smolfire facet keeps filesystem-native
# version details so the exporter does not need a second lineage database.
def build-dataset-facets [dataset: record] {
    let version = $dataset | get version? | default null
    if $version == null {
        return {}
    }

    let dataset_version = $version | get identity? | default ""
    if ($dataset_version | str length) == 0 {
        return {}
    }

    let filesystem = $version | get filesystem? | default ""
    let kind = $version | get kind? | default ""
    let extra = record-without $version [identity filesystem kind]

    mut native_facet = (
        base-facet $SMOLFIRE_FILESYSTEM_VERSION_FACET_SCHEMA_URL
        | merge {
            datasetVersion: $dataset_version
            filesystem: $filesystem
            kind: $kind
        }
    )
    if not ($extra | is-empty) {
        $native_facet = $native_facet | merge {details: $extra}
    }

    {
        version: (
            base-facet $DATASET_VERSION_FACET_SCHEMA_URL
            | merge {datasetVersion: $dataset_version}
        )
        smolfireFilesystemVersion: $native_facet
    }
}

# Normalize one filesystem object/path into an OpenLineage dataset.
def build-dataset [dataset: record] {
    let namespace = $dataset | get namespace? | default ""
    let name = $dataset | get name? | default ($dataset | get path? | default "")
    if ($namespace | str length) == 0 or ($name | str length) == 0 {
        fail "each dataset requires namespace and name (or path)"
    }

    let facets = build-dataset-facets $dataset
    if ($facets | is-empty) {
        return {
            namespace: $namespace
            name: $name
        }
    }

    {
        namespace: $namespace
        name: $name
        facets: $facets
    }
}

# Project one compact internal record into one deterministic OpenLineage RunEvent.
export def project-record [doc: record] {
    require-schema-version $doc

    let event_type = infer-event-type $doc
    let event_time = $doc | get event_time? | default ""
    if ($event_time | str length) == 0 {
        fail "event_time is required"
    }

    let job = $doc | get job? | default {}
    let job_namespace = $job | get namespace? | default ""
    let job_name = $job | get name? | default ""
    if ($job_namespace | str length) == 0 or ($job_name | str length) == 0 {
        fail "job.namespace and job.name are required"
    }

    let run = $doc | get run? | default {}
    let run_id = $run | get run_id? | default ""
    if ($run_id | str length) == 0 {
        fail "run.run_id is required"
    }

    mut run_facets = (
        {
            smolfireBopRun: (
                base-facet $SMOLFIRE_BOP_RUN_FACET_SCHEMA_URL
                | merge {
                    stateFrom: ($run | get state_from? | default "")
                    stateTo: ($run | get state_to? | default "")
                    attempt: ($run | get attempt? | default 0)
                }
            )
        }
    )

    let lease_id = $run | get lease_id? | default ""
    if ($lease_id | str length) > 0 {
        $run_facets = $run_facets | upsert smolfireBopRun ($run_facets.smolfireBopRun | merge {leaseId: $lease_id})
    }

    let binding = $run | get binding? | default null
    if $binding != null {
        $run_facets = $run_facets | upsert smolfireBopRun ($run_facets.smolfireBopRun | merge {binding: $binding})
    }

    let source = $doc | get source? | default null
    if $source != null {
        $run_facets = $run_facets | upsert smolfireBopRun ($run_facets.smolfireBopRun | merge {source: $source})
    }

    let parent = $doc | get parent? | default null
    if $parent != null {
        $run_facets = $run_facets | merge (build-parent-run-facet $parent)
    }

    let dependencies = $doc | get dependencies? | default []
    if not ($dependencies | is-empty) {
        $run_facets = $run_facets | merge (build-job-dependencies-facet $dependencies)
    }

    let inputs = (
        $doc
        | get inputs? | default []
        | each {|dataset| build-dataset $dataset}
        | sort-by namespace name
    )
    let outputs = (
        $doc
        | get outputs? | default []
        | each {|dataset| build-dataset $dataset}
        | sort-by namespace name
    )

    {
        eventTime: $event_time
        producer: $TOOL_PRODUCER
        schemaURL: $RUN_EVENT_SCHEMA_URL
        eventType: $event_type
        job: {
            namespace: $job_namespace
            name: $job_name
            facets: (build-job-facets $job)
        }
        run: {
            runId: $run_id
            facets: $run_facets
        }
        inputs: $inputs
        outputs: $outputs
    }
}

# Project and deterministically sort multiple records.
export def project-records [docs: list<record>] {
    $docs
    | each {|doc|
        let event = project-record $doc
        {
            sort_key: ([
                $event.eventTime
                $event.job.namespace
                $event.job.name
                $event.run.runId
                $event.eventType
            ] | str join "|")
            event: $event
        }
    }
    | sort-by sort_key
    | each {|row| $row.event }
}

# Load one record or a list of records from JSON.
def load-docs [from: string] {
    let raw = if $from == "-" {
        $in | into string
    } else {
        open --raw $from
    }
    let trimmed = $raw | str trim
    if ($trimmed | str length) == 0 {
        fail "input is empty"
    }

    let parsed = try {
        $trimmed | from json
    } catch {|err|
        fail $"failed to parse JSON input: ($err.msg)"
    }

    let kind = $parsed | describe
    if ($kind | str starts-with "record") {
        return [$parsed]
    }
    if ($kind | str starts-with "list") or ($kind | str starts-with "table") {
        return $parsed
    }

    fail $"expected a record or list of records, got ($kind)"
}

export def main [
    --from: string = "-"  # path to a JSON record/list, or - for stdin
    --pretty              # pretty-print the output JSON
] {
    let docs = load-docs $from
    let events = project-records $docs
    if $pretty {
        print ($events | to json --indent 2)
    } else {
        print ($events | to json --raw)
    }
}
