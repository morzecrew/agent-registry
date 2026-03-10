_inv_dir := invocation_directory()
_git_check := require("git")
_awk_check := require("awk")

# ....................... #


[no-exit-message]
[arg("repo", long, help="Public git repo url")]
[arg("ref", long, help="Reference marker to pull: tag / branch / commit")]
[arg("path", long, help="Reference path to pull")]
[arg("agent", long, help="Agent type to pull for", pattern="antigravity|cursor")]
[arg("type", long, help="Type of artifact to pull", pattern="skill|rule|workflow")]
[arg("target", long, help="Explicit target dir or ''")]
[arg("force", long, value="true", help="Force overwrite artifacts in the target directory")]
pull-agent-artifacts repo="morzecrew/agent-registry" ref="main" type="skill" path="skills/*" agent="cursor" target="" force="false":
    #!/usr/bin/env bash

    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    repo_dir="$tmp_dir/repo"
    stage_dir="$tmp_dir/stage"
    mkdir -p "$repo_dir" "$stage_dir"

    # prepare repo url
    repo_input="{{repo}}"

    case "$repo_input" in
        http://*|https://*|git@*|ssh://*)
            repo_url="$repo_input"
            ;;
        *)
            repo_url="https://github.com/$repo_input"
            ;;
    esac

    echo "Repo URL: $repo_url"

    # validate path
    case "{{path}}" in
        "")
            echo "error: path must not be empty" >&2
            exit 1
            ;;
        "*")
            echo "error: '*' alone is not allowed; use path/to/dir/*" >&2
            exit 1
            ;;
        *"**"*)
            echo "error: '**' is not supported" >&2
            exit 1
            ;;
        *"/*/"*|*"*/*"*|*"/*"*"/"* )
            # keep strict: wildcard only allowed as trailing /*
            if [[ "{{path}}" != */\* ]]; then
                echo "error: wildcard is only allowed as trailing '/*'" >&2
                exit 1
            fi
            ;;
    esac

    if [[ "{{path}}" == */\* ]]; then
        checkout_path="${PATH_STRIPPED:-{{path}}}"
        checkout_path="${checkout_path%/\*}"
        mode="dir"
    else
        checkout_path="{{path}}"
        mode="file"
    fi

    if [[ -z "$checkout_path" || "$checkout_path" == "." ]]; then
        echo "error: invalid checkout path" >&2
        exit 1
    fi

    # resolve target root
    resolved_target="{{ target }}"

    if [[ -z "$resolved_target" ]]; then
        case "{{agent}}" in
        antigravity)
            case "{{type}}" in
            skill)    resolved_target="{{_inv_dir}}/.agent/skills" ;;
            rule)     resolved_target="{{_inv_dir}}/.agent/rules" ;;
            workflow) resolved_target="{{_inv_dir}}/.agent/workflows" ;;
            *)
                echo "error: unknown type '{{type}}'" >&2
                exit 1
                ;;
            esac
            ;;
        cursor)
            case "{{type}}" in
            skill)    resolved_target="{{_inv_dir}}/.cursor/skills" ;;
            rule)     resolved_target="{{_inv_dir}}/.cursor/rules" ;;
            workflow) resolved_target="{{_inv_dir}}/.cursor/commands" ;;
            *)
                echo "error: unknown type '{{type}}'" >&2
                exit 1
                ;;
            esac
            ;;
        "")
            echo "error: either target or agent must be provided" >&2
            exit 1
            ;;
        *)
            echo "error: unknown agent '{{agent}}'" >&2
            exit 1
            ;;
        esac
    fi

    mkdir -p "$resolved_target"

    # sparse checkout
    git -C "$repo_dir" init -q
    git -C "$repo_dir" remote add origin "$repo_url"
    git -C "$repo_dir" config core.sparseCheckout true

    mkdir -p "$repo_dir/.git/info"
    printf '%s\n' "$checkout_path" > "$repo_dir/.git/info/sparse-checkout"

    if ! git -C "$repo_dir" fetch --depth=1 --filter=blob:none origin "{{ ref }}" >/dev/null 2>&1; then
        if ! git -C "$repo_dir" fetch --filter=blob:none origin "{{ ref }}" >/dev/null 2>&1; then
            echo "error: failed to fetch ref '{{ ref }}' from '{{ repo }}'" >&2
            exit 1
        fi
    fi

    git -C "$repo_dir" checkout -q FETCH_HEAD

    local_src="$repo_dir/$checkout_path"

    if [[ ! -e "$local_src" ]]; then
        echo "error: path not found in repository at ref '{{ ref }}': {{ path }}" >&2
        exit 1
    fi

    # detect artifacts
    manifest="$tmp_dir/manifest.tsv"
    : > "$manifest"

    detect_kind() {
        local p="$1"
        local forced="{{type}}"
        local ext="${p##*.}"

        if [[ -d "$p" && -f "$p/SKILL.md" ]]; then
            echo "skill"
            return 0
        fi

        if [[ -f "$p" && "$p" == *.mdc ]]; then
            echo "rule"
            return 0
        fi

        if [[ -f "$p" && "$p" == *.md ]]; then
            echo "workflow"
            return 0
        fi

        echo ""
    }

    validate_rule() {
        local f="$1"

        if [[ ! -f "$f" ]]; then
        echo "error: rule '$f' does not exist" >&2
        return 1
        fi

        awk '
            BEGIN {
                in_frontmatter = 0
                seen_start = 0
                seen_end = 0
                has_description = 0
            }
            NR == 1 {
                if ($0 != "---") {
                exit 10
                }
                seen_start = 1
                in_frontmatter = 1
                next
            }
            in_frontmatter && $0 == "---" {
                seen_end = 1
                in_frontmatter = 0
                exit
            }
            in_frontmatter && $0 ~ /^description[[:space:]]*:/ {
                has_description = 1
            }
            END {
                if (!seen_start) exit 10
                if (!seen_end) exit 11
                if (!has_description) exit 12
            }
        ' "$f"

        case "$?" in
        0)
            ;;
        10)
            echo "error: rule '$f' has no frontmatter" >&2
            return 1
            ;;
        11)
            echo "error: rule '$f' frontmatter is not closed" >&2
            return 1
            ;;
        12)
            echo "error: rule '$f' frontmatter has no description:" >&2
            return 1
            ;;
        *)
            echo "error: failed to validate rule '$f'" >&2
            return 1
            ;;
        esac
    }

    validate_workflow() {
        local f="$1"
        # soft validation: accept any .md
        test -f "$f"
    }

    add_artifact() {
        local kind="$1"
        local src="$2"
        local name dest

        case "$kind" in
            skill)
                name="$(basename "$src")"
                dest="$resolved_target/$name"
                ;;
            rule|workflow)
                name="$(basename "$src")"
                dest="$resolved_target/$name"
                ;;
            *)
                echo "error: internal unknown kind '$kind'" >&2
                exit 1
                ;;
        esac

        printf '%s\t%s\t%s\t%s\n' "$kind" "$src" "$name" "$dest" >> "$manifest"
    }

    if [[ "$mode" == "file" ]]; then
        kind="$(detect_kind "$local_src")"
        if [[ -z "$kind" ]]; then
            echo "error: unsupported artifact: {{ path }}" >&2
            exit 1
        fi

        if [[ "{{ type }}" != "auto" && "{{ type }}" != "$kind" ]]; then
            echo "error: type mismatch: requested '{{ type }}', detected '$kind'" >&2
            exit 1
        fi

        case "$kind" in
            rule) validate_rule "$local_src" ;;
            workflow) validate_workflow "$local_src" ;;
            skill) test -f "$local_src/SKILL.md" ;;
        esac

        add_artifact "$kind" "$local_src"
    else
        # path/to/dir/*
        if [[ -f "$local_src/SKILL.md" ]]; then
            kind="skill"

            if [[ "{{ type }}" != "auto" && "{{ type }}" != "skill" ]]; then
                echo "error: type mismatch: requested '{{ type }}', detected 'skill'" >&2
                exit 1
            fi

            add_artifact "skill" "$local_src"
        else
            found_any="false"

            if [[ "{{ type }}" == "skill" || "{{ type }}" == "auto" ]]; then
                while IFS= read -r -d '' skill_file; do
                    skill_dir="$(dirname "$skill_file")"
                    add_artifact "skill" "$skill_dir"
                    found_any="true"
                done < <(find "$local_src" -mindepth 2 -type f -name 'SKILL.md' -print0)
            fi

            if [[ "{{type}}" == "rule" || "{{type}}" == "workflow" || "{{type}}" == "auto" ]]; then
                while IFS= read -r -d '' f; do
                    kind="$(detect_kind "$f")"
                    [[ -z "$kind" ]] && continue

                    if [[ "{{type}}" != "auto" && "{{type}}" != "$kind" ]]; then
                        continue
                    fi

                    case "$kind" in
                        rule) validate_rule "$f" ;;
                        workflow) validate_workflow "$f" ;;
                    esac

                    add_artifact "$kind" "$f"
                    found_any="true"
                done < <(find "$local_src" -type f \( -name '*.mdc' -o -name '*.md' \) ! -name 'SKILL.md' -print0)
            fi

            if [[ "$found_any" != "true" ]]; then
                echo "error: no matching artifacts found under {{path}}" >&2
                exit 1
            fi
        fi
    fi

    # deduplicate artifacts (by destination path)
    manifest_dedup="$tmp_dir/manifest.dedup"

    awk -F'\t' '!seen[$4]++' "$manifest" > "$manifest_dedup"
    mv "$manifest_dedup" "$manifest"

    # conflicts
    conflicts="$tmp_dir/conflicts.txt"
    : > "$conflicts"

    while IFS=$'\t' read -r kind src name dest; do
        if [[ -e "$dest" ]]; then
            printf '%s\n' "$dest" >> "$conflicts"
        fi
    done < "$manifest"

    if [[ -s "$conflicts" && "{{ force }}" != "true" ]]; then
        echo "error: target already contains one or more artifacts:" >&2
        sed 's/^/  - /' "$conflicts" >&2
        exit 1
    fi

    # stage copies
    while IFS=$'\t' read -r kind src name dest; do
        staged="$stage_dir/$name"
        rm -rf "$staged"

        if [[ -d "$src" ]]; then
            cp -R "$src" "$staged"
        else
            mkdir -p "$(dirname "$staged")"
            cp "$src" "$staged"
        fi
    done < "$manifest"

    # install
    while IFS=$'\t' read -r kind src name dest; do
        staged="$stage_dir/$name"

        if [[ "{{ force }}" == "true" && -e "$dest" ]]; then
            rm -rf "$dest"
        fi

        mv "$staged" "$dest"
    done < "$manifest"

    echo "installed to: $resolved_target"
    while IFS=$'\t' read -r kind src name dest; do
        echo "$kind  $dest"
    done < "$manifest"

    