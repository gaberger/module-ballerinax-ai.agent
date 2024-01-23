// Copyright (c) 2023 WSO2 LLC (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
import ballerina/io;
import ballerina/log;

# Execution progress record
public type ExecutionProgress record {|
    # Question to the agent
    string query;
    # Execution history up to the current action
    ExecutionStep[] history = [];
    # Contextual instruction that can be used by the agent during the execution
    map<json>|string? context = ();
|};

# Execution step information
public type ExecutionStep record {|
    # Response generated by the LLM
    json llmResponse;
    # Observations produced by the tool during the execution
    anydata|error observation;
|};

# Execution step information
public type ExecutionResult record {|
    # Tool decided by the LLM during the reasoning
    LlmToolResponse tool;
    # Observations produced by the tool during the execution
    anydata|error observation;
|};

public type ExecutionError record {|
    # Response generated by the LLM
    json llmResponse;
    # Error caused during the execution
    LlmInvalidGenerationError|ToolExecutionError 'error;
|};

# An chat response by the LLM
public type LlmChatResponse record {|
    # A text response to the question
    string content;
|};

# Tool selected by LLM to be performed by the agent
public type LlmToolResponse record {|
    # Name of the tool to selected
    string name;
    # Input to the tool
    map<json>? arguments = {};
|};

# Output from executing an action
public type ToolOutput record {|
    # Output value the tool
    anydata|error value;
|};

public type BaseAgent distinct isolated object {
    LlmModel model;
    ToolStore toolStore;

    # Use LLMs to decide the next tool/step.
    #
    # + progress - QueryProgress with the current query and execution history
    # + return - NextAction decided by the LLM or an error if call to the LLM fails
    isolated function selectNextTool(ExecutionProgress progress) returns json|LlmError;

    # Parse the llm response and extract the tool to be executed.
    #
    # + llmResponse - Raw LLM response
    # + return - SelectedTool or an error if parsing fails
    isolated function parseLlmResponse(json llmResponse) returns LlmToolResponse|LlmChatResponse|LlmInvalidGenerationError;
};

# An iterator to iterate over agent's execution
public class Iterator {
    *object:Iterable;
    private final Executor executor;

    # Initialize the iterator with the agent and the query.
    #
    # + agent - Agent instance to be executed
    # + query - Natural language query to be executed by the agent
    # + context - Contextual information to be used by the agent during the execution
    public isolated function init(BaseAgent agent, string query, map<json>|string? context = ()) {
        self.executor = new (agent, query = query, context = context);
    }

    # Iterate over the agent's execution steps.
    # + return - a record with the execution step or an error if the agent failed
    public function iterator() returns object {
        public function next() returns record {|ExecutionResult|LlmChatResponse|ExecutionError|error value;|}?;
    } {
        return self.executor;
    }
}

# An executor to perform step-by-step execution of the agent.
public class Executor {
    private boolean isCompleted = false;
    private final BaseAgent agent;
    # Contains the current execution progress for the agent and the query
    public ExecutionProgress progress;

    # Initialize the executor with the agent and the query.
    #
    # + agent - Agent instance to be executed
    # + query - Natural language query to be executed by the agent
    # + history - Execution history of the agent (This is used to continue an execution paused without completing)
    # + context - Contextual information to be used by the agent during the execution
    public isolated function init(BaseAgent agent, *ExecutionProgress progress) {
        self.agent = agent;
        self.progress = progress;
    }

    # Checks whether agent has more steps to execute.
    #
    # + return - True if agent has more steps to execute, false otherwise
    public isolated function hasNext() returns boolean {
        return !self.isCompleted;
    }

    # Reason the next step of the agent.
    #
    # + return - generated LLM response during the reasoning or an error if the reasoning fails
    public isolated function reason() returns json|TaskCompletedError|LlmError {
        if self.isCompleted {
            return error TaskCompletedError("Task is already completed. No more reasoning is needed.");
        }
        return check self.agent.selectNextTool(self.progress);
    }

    # Execute the next step of the agent.
    #
    # + llmResponse - LLM response containing the tool to be executed and the raw LLM output
    # + return - Observations from the tool can be any|error|null
    public isolated function act(json llmResponse) returns ExecutionResult|LlmChatResponse|ExecutionError {
        LlmToolResponse|LlmChatResponse|LlmInvalidGenerationError parseLlmResponse = self.agent.parseLlmResponse(llmResponse);
        if parseLlmResponse is LlmChatResponse {
            self.isCompleted = true;
            return parseLlmResponse;
        }

        anydata observation;
        ExecutionResult|ExecutionError executionResult;
        if parseLlmResponse is LlmToolResponse {
            ToolOutput|ToolExecutionError|LlmInvalidGenerationError output = self.agent.toolStore.execute(parseLlmResponse);
            if output is error {
                if output is ToolNotFoundError {
                    observation = "Tool is not found. Please check the tool name and retry.";
                } else if output is ToolInvalidInputError {
                    observation = "Tool execution failed due to invalid inputs. Retry with correct inputs.";
                } else {
                    observation = "Tool execution failed. Retry with correct inputs.";
                }
                executionResult = {
                    llmResponse,
                    'error: output
                };
            } else {
                anydata|error value = output.value;
                observation = value is error ? value.toString() : value;
                executionResult = {
                    tool: parseLlmResponse,
                    observation: value
                };
            }
        } else {
            observation = "Tool extraction failed due to invalid JSON_BLOB. Retry with correct JSON_BLOB.";
            executionResult = {
                llmResponse,
                'error: parseLlmResponse
            };
        }
        self.update({
            llmResponse,
            observation
        });
        return executionResult;
    }

    # Update the agent with an execution step.
    #
    # + step - Latest step to be added to the history
    public isolated function update(ExecutionStep step) {
        self.progress.history.push(step);
    }

    # Reason and execute the next step of the agent.
    #
    # + return - A record with ExecutionResult, chat response or an error 
    public isolated function next() returns record {|ExecutionResult|LlmChatResponse|ExecutionError|error value;|}? {
        if self.isCompleted {
            return ();
        }
        json|TaskCompletedError|LlmError llmResponse = self.reason();
        if llmResponse is error {
            return {value: llmResponse};
        }
        return {value: self.act(llmResponse)};
    }
}

# Execute the agent for a given user's query.
#
# + agent - Agent to be executed
# + query - Natural langauge commands to the agent  
# + maxIter - No. of max iterations that agent will run to execute the task (default: 5)
# + context - Context values to be used by the agent to execute the task
# + verbose - If true, then print the reasoning steps (default: true)
# + return - Returns the execution steps tracing the agent's reasoning and outputs from the tools
public isolated function run(BaseAgent agent, string query, int maxIter = 5, string|map<json> context = {}, boolean verbose = true) returns record {|(ExecutionResult|ExecutionError)[] steps; string answer?;|} {
    (ExecutionResult|ExecutionError)[] steps = [];
    string? content = ();
    Iterator iterator = new (agent, query, context = context);
    int iter = 0;
    foreach ExecutionResult|LlmChatResponse|ExecutionError|error step in iterator {
        if iter == maxIter {
            break;
        }
        if step is error {
            error? cause = step.cause();
            log:printError("Error occured while executing the agent", step, cause = cause !is () ? cause.toString() : "");
            break;
        }
        if step is LlmChatResponse {
            content = step.content;
            if verbose {
                io:println(string `${"\n\n"}Final Answer: ${step.content}${"\n\n"}`);
            }
            break;
        }
        iter += 1;
        if verbose {
            io:println(string `${"\n\n"}Agent Iteration ${iter.toString()}`);
            if step is ExecutionResult {
                LlmToolResponse tool = step.tool;
                io:println(string `Action:
${BACKTICKS}
{
    ${ACTION_NAME_KEY}: ${tool.name},
    ${ACTION_ARGUEMENTS_KEY}: ${(tool.arguments ?: "None").toString()}}
}
${BACKTICKS}`);
                anydata|error observation = step?.observation;
                if observation is error {
                    io:println(string `${OBSERVATION_KEY} (Error): ${observation.toString()}`);
                } else if observation !is () {
                    io:println(string `${OBSERVATION_KEY}: ${observation.toString()}`);
                }
            } else {
                error? cause = step.'error.cause();
                io:println(string `LLM Generation Error: 
${BACKTICKS}
{
    message: ${step.'error.message()},
    cause: ${(cause is error ? cause.message() : "Unspecified")},
    llmResponse: ${step.llmResponse.toString()}
}
${BACKTICKS}`);
            }
        }
        steps.push(step);
    }
    return {steps, answer: content};
}

isolated function getObservationString(anydata|error observation) returns string {
    if observation is () {
        return "Tool didn't return anything. Probably it is successful. Should we verify using another tool?";
    } else if observation is error {
        record {|string message; string cause?;|} errorInfo = {
            message: observation.message().trim()
        };
        error? cause = observation.cause();
        if cause is error {
            errorInfo.cause = cause.message().trim();
        }
        return "Error occured while trying to execute the tool: " + errorInfo.toString();
    } else {
        return observation.toString().trim();
    }
}

# Get the tools registered with the agent.
#
# + agent - Agent instance
# + return - Array of tools registered with the agent
public isolated function getTools(BaseAgent agent) returns AgentTool[] {
    return agent.toolStore.tools.toArray();
}
