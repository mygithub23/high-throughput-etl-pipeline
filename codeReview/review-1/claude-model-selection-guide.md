# Claude Model Selection Guide & Hybrid AI Development Workflow

## Table of Contents
- [Claude Model Comparison](#claude-model-comparison)
- [Version Numbers Explained](#version-numbers-explained)
- [Recommendations for AWS/Python Development](#recommendations-for-awspython-development)
- [When to Use Each Model](#when-to-use-each-model)
- [Practical Workflow](#practical-workflow)
- [Quick Decision Tree](#quick-decision-tree)
- [Complete Hybrid Workflow Setup](#complete-hybrid-workflow-setup)
- [Quick Commands Reference](#quick-commands-reference)
- [Troubleshooting](#troubleshooting)

---

## Claude Model Comparison

| Model | Speed | Intelligence | Cost | Best For |
|-------|-------|--------------|------|----------|
| **Haiku** | ⚡⚡⚡ Fastest | 🧠 Good | 💰 Cheapest | Quick tasks, simple code, formatting |
| **Sonnet** | ⚡⚡ Fast | 🧠🧠🧠 Very Smart | 💰💰 Moderate | **Most development work** |
| **Opus** | ⚡ Slower | 🧠🧠🧠🧠 Most Capable | 💰💰💰 Expensive | Complex reasoning, architecture |

---

## Version Numbers Explained

### Claude Generations

**Claude 4.x vs 3.x:**
- **4.x** = Latest generation (more capable, better reasoning)
- **3.x** = Previous generation (still good, but superseded)

**Within 4.x:**
- **4.1** = Earlier version
- **4.5** = Latest and best ⭐ (use this!)

### Model Hierarchy

```
Claude Opus 4.5     > Claude Opus 4.1     > Claude Opus 3.5
Claude Sonnet 4.5   > Claude Sonnet 4     > Claude Sonnet 3.5
Claude Haiku 4.5    > (no older Haiku versions in common use)
```

---

## Recommendations for AWS/Python Development

### 🏆 Best Choice: Claude Sonnet 4.5

**Why Sonnet 4.5 for AWS/Python work:**

```
✅ Excellent at Python code (boto3, Lambda, etc.)
✅ Understands AWS services deeply
✅ Great at following architectural plans
✅ Fast enough for iterative development
✅ Cost-effective for daily use
✅ Handles complex multi-file projects
✅ Good at infrastructure-as-code (Terraform/CloudFormation)
```

**Perfect for:**
- Writing Lambda functions
- AWS SDK (boto3) code
- Data transformation scripts
- Infrastructure automation
- Following design phase plans
- Debugging and refactoring
- Glue jobs and Step Functions
- SQS/SNS integration
- Cross-account migrations

---

## When to Use Each Model

### Use Haiku 4.5 for:

```bash
# Quick, simple tasks
- Code formatting
- Adding comments/docstrings
- Simple bug fixes
- Writing unit tests
- Quick syntax questions
- README updates
- Simple file operations
```

**Example tasks:**
```python
# Good for Haiku:
"Add type hints to this function"
"Format this code according to PEP 8"
"Write docstrings for these methods"
"Create a simple pytest test for this function"
```

---

### Use Sonnet 4.5 for: ⭐ YOUR DEFAULT

```bash
# 90% of your development work
- Implementing features from design docs
- Writing Lambda/Glue/Step Functions code
- Creating Terraform/CloudFormation templates
- Debugging complex issues
- AWS service integration
- Multi-file refactoring
- API development
- Database interactions
- Error handling and logging
```

**Example tasks:**
```python
# Perfect for Sonnet:
"Implement a Lambda function that processes SQS messages and stores results in DynamoDB"
"Create a Glue job to transform data from S3 and load into Redshift"
"Write a Step Function to orchestrate this multi-stage data pipeline"
"Refactor this boto3 code to handle cross-account IAM role assumption"
"Debug why my Lambda function is timing out when processing large SQS batches"
```

---

### Use Opus 4.5 for:

```bash
# Only for complex architectural decisions
- System design (but prefer Gemini in Antigravity for initial design)
- Complex algorithm optimization
- Security review of entire codebase
- Performance optimization analysis
- Critical production code review
- Advanced architectural patterns
```

**Example tasks:**
```python
# Reserve for Opus:
"Analyze this entire microservices architecture for security vulnerabilities"
"Optimize this data processing pipeline for 10x throughput"
"Design a fault-tolerant distributed system for real-time data processing"
"Review this financial transaction system for edge cases and race conditions"
```

**Note:** For most architectural work, use **Gemini 3 Pro in Google Antigravity** during the design phase - it's excellent for brainstorming and planning!

---

## Practical Workflow

### Phase 1: Design (Antigravity - Gemini 3 Pro)

**Use Gemini for:**
```
- Architecture diagrams (Mermaid)
- AWS service selection
- Cost estimation
- Infrastructure planning
- Multiple solution comparisons
- Brainstorming approaches
```

**Example workflow in Antigravity:**
```
Prompt: "I need to design a serverless data pipeline that:
- Ingests data from multiple SQS queues
- Transforms data using Lambda
- Stores in DynamoDB and S3
- Budget: $100/month
- Expected load: 10M messages/day

Create:
1. Architecture diagram (Mermaid)
2. AWS resource breakdown with costs
3. Scaling considerations
4. Implementation plan"
```

---

### Phase 2: Implementation (OpenCode - Claude Sonnet 4.5) ⭐

**Use Sonnet for:**
```
- Writing all Python code
- Creating IaC templates
- Following the design plan
- Testing and debugging
- Iterative development
```

**Example workflow in OpenCode:**
```bash
# Start OpenCode in your project directory
cd ~/projects/data-pipeline
opencode

# Select: Claude Sonnet 4.5 (Antigravity)

# Reference the design document
@DESIGN.md

# Prompt:
"Implement this data pipeline step by step:

Phase 1: Create project structure
Phase 2: Implement SQS consumer Lambda
Phase 3: Add data transformation logic
Phase 4: Create DynamoDB tables (Terraform)
Phase 5: Add S3 integration
Phase 6: Write tests

Follow the architecture in DESIGN.md. Ask before running any AWS commands."
```

---

### Phase 3: Review (Antigravity - Claude Opus 4.5 if needed)

**Use Opus only if:**
```
- Need deep security review
- Complex optimization required
- Critical production code
- Advanced architectural refactoring
```

---

## Quick Decision Tree

```
Is it a simple task (< 50 lines, clear requirements)?
└─ YES → Haiku 4.5
└─ NO → Continue...

Is it implementation following a clear plan?
└─ YES → Sonnet 4.5 ⭐ (YOUR GO-TO)
└─ NO → Continue...

Is it complex architecture or critical optimization?
└─ YES → Opus 4.5 (or Gemini for design)
└─ NO → Default to Sonnet 4.5
```

**Rule of thumb:** When in doubt, use **Sonnet 4.5**. It's the sweet spot for 90% of development work.

---

## Complete Hybrid Workflow Setup

### Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                YOUR DEVELOPMENT WORKFLOW                 │
└─────────────────────────────────────────────────────────┘
                            ↓
                ┌───────────────────────┐
                │  DESIGN PHASE         │
                │  (Antigravity)        │
                │  - Gemini 3 Pro       │
                │  - Architecture       │
                │  - Planning           │
                │  - Diagrams           │
                └───────────┬───────────┘
                            │
                            │ Export plan/context
                            ↓
                ┌───────────────────────┐
                │  IMPLEMENTATION       │
                │  (OpenCode)           │
                │  - Claude Sonnet 4.5  │
                │  - Code execution     │
                │  - Testing            │
                │  - Debugging          │
                └───────────┬───────────┘
                            │
                            │ Results back
                            ↓
                ┌───────────────────────┐
                │  VALIDATION           │
                │  (Antigravity)        │
                │  - Review changes     │
                │  - Documentation      │
                │  - Browser testing    │
                └───────────────────────┘
```

---

### Tools & Models Available

**In OpenCode (Terminal):**
```
✅ Claude Sonnet 4.5 (Antigravity) - FREE ⭐ Use for implementation
✅ Gemini 2.5 Pro - FREE
✅ Gemini 2.5 Flash - FREE
✅ Gemini 2.0 variants - FREE
✅ Gemini 1.5 variants - FREE
```

**In Antigravity (IDE):**
```
✅ Gemini 3 Pro - FREE ⭐ Use for design
✅ Claude Sonnet 4.5 - FREE
```

**Cost:** $0 during Antigravity preview period! 🎉

---

## Quick Commands Reference

### OpenCode Commands

```bash
# Start OpenCode
opencode

# Switch models
/models

# Reference files in prompts
@filename.py
@DESIGN.md
@/path/to/file.py

# View help
/help

# Exit OpenCode
Ctrl+C
# or type:
exit

# Run with debug output
OPENCODE_ANTIGRAVITY_DEBUG=2 opencode
```

---

### Model Selection in OpenCode

```bash
# In OpenCode, press '/' and type:
/models

# Use arrow keys to navigate to:
Claude Sonnet 4.5 (Antigravity)

# Press Enter to select
```

---

### Antigravity Commands

```bash
# Launch Antigravity
antigravity

# In Antigravity:
Cmd/Ctrl + K     # Command palette
/model           # Switch models
/export          # Export code
Tab              # Switch between agents
```

---

## Workflow Examples

### Example 1: AWS Lambda Function

**Step 1: Design in Antigravity (Gemini 3 Pro)**

```
Create a detailed design for a Lambda function that:
- Processes SQS messages containing JSON data
- Validates the data structure
- Stores valid records in DynamoDB
- Sends invalid records to SNS for alerting
- Includes proper error handling and logging

Generate:
1. Architecture diagram (Mermaid)
2. Sequence diagram for data flow
3. AWS resource list
4. IAM permissions needed
5. Implementation checklist

Save to DESIGN.md
```

**Step 2: Implement in OpenCode (Claude Sonnet 4.5)**

```bash
cd ~/projects/lambda-processor
opencode

# Select Claude Sonnet 4.5 (Antigravity)
# Type:

@DESIGN.md

Implement the Lambda function according to the design:

Phase 1: Project setup
- Create directory structure
- Set up requirements.txt
- Configure environment variables

Phase 2: Lambda handler
- Implement SQS event parsing
- Add data validation
- Handle DynamoDB writes
- Add SNS notifications

Phase 3: Testing
- Write unit tests
- Create test events
- Add mocking for AWS services

Start with Phase 1 and wait for approval before proceeding.
```

---

### Example 2: Cross-Account S3 Migration

**Step 1: Design in Antigravity**

```
Design a solution for migrating S3 objects between AWS accounts:

Requirements:
- Source: Account A, 500GB in s3://source-bucket
- Destination: Account B, s3://dest-bucket
- Maintain metadata and tags
- Progress tracking
- Error handling and retry logic
- Cost-effective approach

Deliverables:
1. Architecture diagram
2. IAM roles and policies needed
3. Step-by-step migration plan
4. Cost estimation
5. Rollback strategy
```

**Step 2: Implement in OpenCode**

```bash
opencode

@MIGRATION_DESIGN.md

Implement the S3 migration solution:

1. Create Python script with boto3
2. Implement cross-account role assumption
3. Add object copying with metadata preservation
4. Implement progress tracking (DynamoDB)
5. Add error handling and retry logic
6. Create CloudWatch logging

Include comprehensive error handling and make it production-ready.
```

---

### Example 3: Terraform Infrastructure

**Step 1: Design in Antigravity**

```
Plan Terraform infrastructure for a data processing pipeline:

Components:
- Lambda functions (3 stages)
- SQS queues (dead letter queues)
- DynamoDB tables
- S3 buckets (with lifecycle policies)
- CloudWatch alarms
- SNS topics

Requirements:
- Multi-environment (dev, staging, prod)
- Proper tagging
- Cost optimization
- Security best practices

Create infrastructure architecture and Terraform module structure.
```

**Step 2: Implement in OpenCode**

```bash
opencode

@INFRA_DESIGN.md

Create Terraform modules for this infrastructure:

1. Create module structure:
   - modules/lambda/
   - modules/queues/
   - modules/storage/
   - modules/monitoring/

2. Implement each module with:
   - variables.tf
   - main.tf
   - outputs.tf
   - README.md

3. Create environments:
   - environments/dev/
   - environments/staging/
   - environments/prod/

Follow AWS and Terraform best practices.
```

---

## Best Practices

### 1. **Always Reference Design Documents**

```bash
# In OpenCode, always reference your design:
@DESIGN.md
@ARCHITECTURE.md
@PLAN.md

# This keeps Claude focused on your architecture
```

### 2. **Break Down Complex Tasks**

```bash
# Good approach:
"Implement Phase 1: Project setup
Wait for approval before Phase 2"

# Not ideal:
"Build the entire system"
```

### 3. **Use Type Hints and Documentation**

```python
# Always request:
"Include type hints, docstrings, and comprehensive error handling"
```

### 4. **Iterate and Test**

```bash
# After implementation:
"Now write pytest tests for this code"
"Add integration tests"
"Create mock AWS resources"
```

### 5. **Cost Awareness**

```bash
# Always ask:
"Estimate AWS costs for this solution"
"Suggest cost optimization strategies"
```

---

## Troubleshooting

### Issue: Antigravity Models Not Showing

```bash
# 1. Check plugin installation
npm list -g | grep antigravity

# 2. Verify config
cat ~/.config/opencode/opencode.json

# 3. Check authentication
ls -la ~/.config/opencode/antigravity-accounts.json

# 4. Re-authenticate if needed
rm -f ~/.config/opencode/antigravity-accounts.json
opencode auth login

# 5. Restart OpenCode
pkill opencode
opencode
```

---

### Issue: "No Payment Method" Error

This means you're using regular API models instead of Antigravity models.

**Solution:**
```bash
# In OpenCode, press:
/models

# Look for models with "(Antigravity)" suffix:
✅ Claude Sonnet 4.5 (Antigravity)  # FREE
❌ Claude Sonnet 4.5                 # PAID API

# Select the Antigravity version
```

---

### Issue: Authentication Failed

```bash
# Clear credentials and retry
rm -f ~/.config/opencode/antigravity-accounts.json

# Re-authenticate
opencode auth login

# Select: Google > OAuth with Google (Antigravity)

# Make sure you:
# 1. Have Antigravity installed and working
# 2. Are signed into Google account with Antigravity access
# 3. Complete the browser authentication
```

---

## Advanced Tips

### 1. **Use MCP Servers for Extended Capabilities**

```json
// In ~/.config/opencode/opencode.json
{
  "mcp": {
    "aws-docs": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-aws-kb"]
    },
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    }
  }
}
```

### 2. **Create Custom Skills**

**For Antigravity:** `~/.claude/skills/aws-architect/SKILL.md`

```markdown
# AWS Architecture Planning Skill

You are an expert AWS solutions architect specializing in Python-based serverless applications.

## Your Responsibilities:
1. Design scalable AWS architectures
2. Create Mermaid diagrams
3. Estimate costs
4. Plan security and IAM policies
5. Consider cost optimization

## Always Include:
- Architecture diagram
- Resource breakdown
- Cost estimate
- Security considerations
- Implementation steps
```

**For OpenCode:** `~/.config/opencode/agents/aws-python-builder.md`

```markdown
---
description: AWS Python implementation specialist
mode: build
model: antigravity-claude-sonnet-4-5
temperature: 0.3
tools:
  read: true
  write: true
  edit: true
  bash: true
permissions:
  bash:
    "*": ask
---

# AWS Python Builder

You implement AWS solutions using Python and boto3.

## Your Responsibilities:
1. Follow design documents exactly
2. Write production-ready Python code
3. Include type hints and error handling
4. Create comprehensive tests
5. Document code thoroughly

## AWS Best Practices:
- Use environment variables for config
- Implement proper IAM roles
- Add CloudWatch logging
- Handle AWS service limits
- Optimize for cost
```

---

### 3. **Save Common Prompts as Commands**

Create custom commands in `~/.config/opencode/commands/`:

```bash
# ~/.config/opencode/commands/aws-lambda.md
Create a Python Lambda function that:
- $DESCRIPTION
- Includes type hints
- Has comprehensive error handling
- Uses CloudWatch logging
- Follows boto3 best practices
- Includes unit tests with moto

Ask before running any AWS commands.
```

Usage:
```bash
# In OpenCode:
/aws-lambda DESCRIPTION="processes SQS messages and stores in DynamoDB"
```

---

## Summary

### Quick Reference Card

| Task Type | Model | Location |
|-----------|-------|----------|
| **Design & Planning** | Gemini 3 Pro | Antigravity IDE |
| **Implementation** | Claude Sonnet 4.5 ⭐ | OpenCode Terminal |
| **Quick Fixes** | Haiku 4.5 | OpenCode Terminal |
| **Complex Review** | Opus 4.5 | OpenCode Terminal |

### Key Takeaways

1. ✅ **Use Claude Sonnet 4.5 for 90% of development work**
2. ✅ **Design in Antigravity (Gemini), Implement in OpenCode (Claude)**
3. ✅ **Always reference design documents with @filename**
4. ✅ **Both tools are FREE during Antigravity preview**
5. ✅ **Break complex tasks into phases**

### Success Checklist

- [ ] Antigravity installed and working
- [ ] OpenCode installed with antigravity-auth plugin
- [ ] Can see "Claude Sonnet 4.5 (Antigravity)" in model list
- [ ] Authentication with Google completed
- [ ] Tested with a simple Python/AWS prompt
- [ ] Created design document workflow
- [ ] Ready to build AWS projects!

---

## Additional Resources

- **Antigravity Download:** https://antigravity.google/download
- **Antigravity Docs:** https://codelabs.developers.google.com/getting-started-google-antigravity
- **OpenCode Docs:** https://opencode.ai/docs
- **Claude Code Skills:** https://docs.claude.com (search for "skills")
- **AWS Best Practices:** https://docs.aws.amazon.com/wellarchitected/

---

**Last Updated:** January 2026
**Version:** 1.0
**Author:** AI-Assisted Development Guide for AWS/Python Work

---

*Happy coding! 🚀*
