#!/usr/bin/env bash

# Path to your action.yml file and README.md
ACTION_YML="action.yml"
README_MD="README.md"

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed. Please install it first."
    exit 1
fi

# Generate table for inputs
generate_inputs_table() {
    local table="| Name | Description | Default |\n"
    table+="|------|-------------|--------|\n"

    # Get all input names
    local input_names=
    input_names=$(yq e '.inputs | keys | .[]' "${ACTION_YML}")

    for name in ${input_names}; do
        # Get description and properly format it
        local description=
        description=$(yq e ".inputs.${name}.description" "${ACTION_YML}")
        # Compress multi-line descriptions and escape pipes
        description=$(echo "${description}" | tr '\n' ' ' | sed 's/|/\\|/g')

        # Get default value
        local default=
        default=$(yq e ".inputs.${name}.default" "${ACTION_YML}")

        # For multi-line default values, show only first line
        if [[ $(echo "${default}" | wc -l) -gt 1 ]]; then
            local first_line=
            first_line=$(echo "${default}" | head -n 1 | sed 's/|/\\|/g')
            default="${first_line} ..."
        else
            default=$(echo "${default}" | sed 's/|/\\|/g')
        fi

        # Truncate long default values
        if [[ ${#default} -gt 50 ]]; then
            default="${default:0:47}..."
        fi

        table+="| \`${name}\` | ${description} | \`${default}\` |\n"
    done

    echo -e "${table}"
}

# Generate table for outputs
generate_outputs_table() {
    local table="| Name | Description |\n"
    table+="|------|-------------|\n"

    # Get all output names
    local output_names=
    output_names=$(yq e '.outputs | keys | .[]' "${ACTION_YML}")

    for name in ${output_names}; do
        local description=
        description=$(yq e ".outputs.${name}.description" "${ACTION_YML}")

        # For complex descriptions like JSON examples, use a simplified approach
        if [[ "${name}" == "json" ]]; then
            description="The changes made by this action, in JSON format. Contains information about updated files, images, and digests."
        else
            # For regular descriptions, flatten them
            description=$(echo "${description}" | tr '\n' ' ' | sed 's/|/\\|/g')
        fi

        table+="| \`${name}\` | ${description} |\n"
    done

    echo -e "${table}"
}

# Generate tables for inputs and outputs
inputs_table=$(generate_inputs_table)
outputs_table=$(generate_outputs_table)

# Combine the tables with headers
markdown_table="### Inputs\n\n${inputs_table}\n\n### Outputs\n\n${outputs_table}\n\n> **Note:** For complete details on inputs and outputs, please refer to the [action.yml](./action.yml) file."

# Check if the end placeholder exists, if not add it
if ! grep -q "<!-- end automated updates do not change -->" "${README_MD}"; then
    echo "<!-- end automated updates do not change -->" >> "${README_MD}"
    echo "Added missing end placeholder to README.md"
fi

# Create a temporary file
temp_file=$(mktemp)

# Extract the content before the begin placeholder
sed -n '1,/<!-- begin automated updates do not change -->/p' "${README_MD}" > "${temp_file}"

# Add our markdown table
echo -e "${markdown_table}" >> "${temp_file}"

# Extract the content after the end placeholder
sed -n '/<!-- end automated updates do not change -->/,$p' "${README_MD}" >> "${temp_file}"

# Replace the original file with the temporary file
mv "${temp_file}" "${README_MD}"

echo "README.md has been updated with the inputs and outputs tables."
