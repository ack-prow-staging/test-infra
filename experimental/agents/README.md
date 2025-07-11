# AWS Controllers for Kubernetes (ACK) Agents

## Overview

The ACK Agents provide conversational interfaces to help you work with AWS Controllers for Kubernetes. The system consists of specialized agents that can work independently or be orchestrated through workflows.

## Architecture

The ACK Agents system follows a workflow-based architecture where different agents collaborate to analyze, generate, and build ACK controllers:

```mermaid
graph TB
    DevTrigger[DevTrigger]
    DevTrigger --> Workflow
    
    Workflow --> ModelAgent[Model Agent Call]
    Workflow --> GeneratorAgent[Generator Agent Call]
    Workflow --> TagAgent[Tag Agent Call]
    
    ModelAgent --> ModelAgentOrch[Model Agent]
    GeneratorAgent --> GeneratorAgentOrch[Generator Agent]
    TagAgent --> TagAgentOrch[Tag Agent]
    
    %% Separate Data Pipeline (Setup Process)
    AWSOrchestratorSDK[AWS API Models] --> S3Bucket[S3 Bucket]
    S3Bucket --> FoundationModel[Foundation Model<br/>Parse]
    FoundationModel --> ChunkedData[Chunked Data]
    ChunkedData --> TitanEmbeddings[Titan Embeddings]
    TitanEmbeddings --> VectorStoreOpenSearch[Vector Store OpenSearch]
    
    %% Model Agent queries the knowledge base and produces analysis files
    VectorStoreOpenSearch --> ModelAgentOrch
    ModelAgentOrch --> AnalysisFiles[Resource Analysis Files<br/>Model Logs]
    
    GeneratorAgentOrch --> BuilderAgent[Builder Agent]
    GeneratorAgentOrch --> MemoryAgent[Memory Agent]
    
    MemoryAgent --> ErrorSolutionMemory[Error/Solution Memory<br/>OpenSearch Vector DB]
    
    TagAgentOrch --> BuilderAgent
    
    BuilderAgent --> ACKRepositories[ACK Repositories<br/>Code Generator, Runtime, Service<br/>Controller]
    GeneratorAgentOrch --> ControllerResource[Controller with<br/>Resource]
    BuilderAgent --> BuildLogs[Build logs]
    GeneratorAgentOrch --> GeneratorYaml[generator.yaml<br/>Service Config]
    
    AnalysisFiles -.-> ControllerResource
    BuildLogs -.-> ControllerResource
    GeneratorYaml -.-> ControllerResource
```

## Agents

### ACK Builder Agent
- Clone and manage ACK repositories (code-generator, runtime, service controllers)
- Build service controllers for AWS services
- Read build logs and check build status

### ACK Generator Agent  
- Examine service controller configurations and API operations
- Generate code and configurations for ACK controllers
- Work with ACK generator.yaml files
- Manage error/solution memory for build troubleshooting

### ACK Model Agent
- Analyze AWS API models from the official AWS API models repository
- Extract comprehensive CRUD operation information for resources
- Provide detailed analysis for ACK controller implementation
- Generate structured analysis files for resources

### ACK Tag Agent
- Write custom hook code to support editing AWS resource tags
- Generate Go code for tagging operations (create, update, read hooks)

## Workflows

### ACK Resource Addition Workflow
An automated workflow that orchestrates multiple agents to add a new resource to an existing ACK service controller:

1. **Service Validation**: Validate if the requested resource has been bootstapped for ACK
2. **Model Agent Phase**: Analyzes AWS API models to extract resource information
3. **Generator Agent Phase**: Updates generator.yaml configuration and builds the controller
4. **Tag Agent Phase**: Adds tagging support if the resource supports tags
5. **Validation Phase**: Ensures the controller builds successfully

## Prerequisites

1. Python 3.10 or higher
2. [uv](https://github.com/astral-sh/uv) - Modern Python package manager
3. AWS account with access to Amazon Bedrock
4. Claude 3.7 Sonnet model access enabled in your AWS account
5. AWS credentials configured in your environment
6. Opensearch Vector Database for memory agent
7. Bedrock Knowledgebase (with ACK Codegen)
8. Bedrock Knowledgebase (AWS API Models)

## Setup

### API Models KB Configuration

#### 1. Data Source Preparation
```bash
# Upload AWS API model JSON files to S3 (auto-generates bucket name)
./utils/scripts/extract_api_models.sh

# Or use environment variable to specify existing bucket
export S3_BUCKET_NAME=my-existing-bucket-name
./utils/scripts/extract_api_models.sh
```

#### 2. Knowledge Base Settings
- **Name**: `api-models-knowledge-base`
- **Data Source**: S3 bucket with AWS API model JSON files
- **Parsing Strategy**: Foundation Model-based with Claude 3.5 Sonnet
- **Chunking Strategy**: Hierarchical
  - Parent chunks: 4000 tokens
  - Child chunks: 600 tokens  
  - Overlap: 120 tokens
- **Embedding Model**: Amazon Titan Text Embeddings V2 (1024 dimensions)
- **Vector Store**: OpenSearch Serverless

#### 3. Environment Variables
```bash
export MODEL_AGENT_KB_ID=your-knowledge-base-id
```

Note: Sync knowledgebase data source

## Installation

This project uses `uv` for dependency management. If you don't have `uv` installed, you can install it following the [official installation instructions](https://github.com/astral-sh/uv#installation).

### Install Development Dependencies (Optional)
```bash
uv sync --extra dev 
```

To run the dev tool you can use

```bash
uv run <tool-name> <args>

# For example
uv run black .
```

### Setting up the project

#### AWS Resources

1. OpenSearch Vector Store

## Usage

### Individual Agents

Run the builder agent:

```bash
# Using make
make run-builder

# Or directly
uv run python -m ack_builder_agent
```

Run the generator agent:

```bash
# Using make
make run-generator

# Or directly
uv run python -m ack_generator_agent
```

Run the model agent:

```bash
# Using make
make run-model

# Or directly
uv run python -m ack_model_agent
```

Run the tag agent:

```bash
# Using make
make run-tag

# Or directly
uv run python -m ack_tag_agent
```

You can provide command-line arguments:

```bash
uv run python -m ack_generator_agent --region us-east-1 --temperature 0.5 --debug
```

### Workflows

#### List Available Workflows

```bash
# Using make
make list-workflows

# Or directly
uv run python -m workflows list
```

#### ACK Resource Addition Workflow

Add a new resource to an existing ACK service controller:

```bash
# Using make
make workflow-add-resource SERVICE=s3 RESOURCE=AccessPoint

# Or directly
uv run python -m workflows resource-addition --service s3 --resource AccessPoint
```

### Available Arguments

- `--region`: AWS region for Bedrock (default: us-west-2)
- `--model`: Model ID for Claude on Bedrock (default: us.anthropic.claude-3-7-sonnet-20250219-v1:0)
- `--temperature`: Temperature for model generation (default: 0.2)
- `--debug`: Enable debug logging

### Available Environment Variables

- `OPENSEARCH_HOST`: OpenSearch Endpoint URL for memory storage and retrieval
- `MODEL_AGENT_KB_ID`: Knowledge Base ID for AWS API models
- `ack_root`: Path to root of ACK Git repos. Defaults to `~/aws-controllers-k8s`.
- `ack_org_url`: URL for the aws-controller-k8s org. Defaults to `https://github.com/aws-controllers-k8s`.
- `code_generator_url`: URL for the code-generator Git repo. Defaults to `{ack_org_url}/code-generator`.
- `code_generator_path_override`: Overrides path to code-generator Git repo. If not set `{ack_root}/code-generator` is used.
- `runtime_url`: URL for the runtime Git repo. Defaults to `{ack_org_url}/runtime`.
- `runtime_path_override`: Overrides path to the runtime Git repo. If not set `{ack_root}/runtime` is used.
- `aws_sdk_go_v2_url`: URL for the aws-sdk-go-v2 Git repo. Defaults to `https://github.com/aws/aws-sdk-go-v2.git`.
- `aws_sdk_go_v2_path_override`: Overrides path to the aws-sdk-go-v2 Git repo. If not set `{ack_root}/aws-sdk-go-v2` is used.
- `build_logs_dir_override`: Overrides path directory where build logs should be saved. If not set `{ack_root}/build_logs` is used.

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details. 