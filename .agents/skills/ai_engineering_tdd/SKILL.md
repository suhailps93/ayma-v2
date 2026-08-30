---
name: ai_engineering_tdd
description: Advanced 2026 AI Engineering workflows, TDD, and agentic development guidelines
---

# 2026 AI Engineering & TDD Workflows

When operating as an AI developer or orchestrating tasks, adhere to the modern standards of intent-based engineering.

## 1. Spec-Driven Development
Before writing any significant feature or system:
*   **Draft a Spec**: Collaborate to write a `spec.md` (or equivalent artifact) outlining the requirements, architecture decisions, data models, and testing strategy.
*   **Prevent AI Slop**: Use the spec as an absolute guardrail. Do not introduce speculative variables, libraries, or unapproved architecture patterns outside the spec.

## 2. Test-Driven Development (TDD) for Agents
TDD is the ultimate feedback loop for AI workflows:
*   **Write Tests First**: Based on the spec, generate failing unit or integration tests *before* implementing the application logic. 
*   **Red-Green-Refactor**: Iteratively write and adjust code until the test passes. 
*   **Self-Healing**: If a test fails, do not blindly alter the core logic without understanding the failure. Read the logs, understand the stack trace, and fix the specific brittle component (e.g., a bad UI selector, a missing mock).

## 3. The "LLM OS" and Orchestration Patterns
*   **Simplicity Over Complexity**: Avoid overly complex linear chains. Prioritize direct tool calls or a simple Perceive-Reason-Act-Reflect (PRAR) loop. 
*   **Tool Standardization**: Utilize MCP (Model Context Protocol) standards when interfacing with new tools rather than writing brittle, custom API wrappers whenever possible.
*   **Observability**: Output intermediate thoughts, assumptions, and tool payloads so the user can observe the "thought process."
*   **Tiered Reasoning**: For simple repetitive tasks, use lightweight execution; save deep reasoning tokens for planning, architectural changes, and debugging.

## 4. Human-in-the-Loop (HITL)
*   Always pause and ask the user for explicit approval before performing high-stakes actions, such as altering production database schemas, modifying payment logic, or changing security configurations.
