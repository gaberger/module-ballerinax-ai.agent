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
import ballerinax/azure.openai.chat as azure_chat;
import ballerinax/azure.openai.text as azure_text;
import ballerinax/openai.chat;
import ballerinax/openai.text;

// TODO: change the configs to extend the config record from the respective clients.
// requirs using never prompt?; never stop? to prevent setting those during initialization
// change once https://github.com/ballerina-platform/ballerina-lang/issues/32012 is fixed

# Roles for the chat messages.
public enum ROLE {
    SYSTEM = "system",
    USER = "user",
    ASSISTANT = "assistant",
    FUNCTION = "function"
}

# Completion model configurations.
public type CompletionModelConfig readonly & record {|
    # Model type to be used for the completion. Default is `davinci`.
    string model = GPT3_MODEL_NAME;
    # Temperature value to be used for the completion. Default is `0.7`.
    decimal temperature = DEFAULT_TEMPERATURE;
    # Maximum number of tokens to be generated for the completion. Default is `512`.
    int max_tokens = DEFAULT_MAX_TOKEN_COUNT;
|};

# Chat model configurations.
public type ChatModelConfig readonly & record {|
    # Model type to be used for the completion. Default is `gpt-3.5-turbo`
    string model = GPT3_5_MODEL_NAME;
    # Temperature value to be used for the completion. Default is `0.7`.
    decimal temperature = DEFAULT_TEMPERATURE;
|};

# User chat message record
public type ChatUserMessage record {|
    # Role of the message
    USER role;
    # Content of the message
    string content;
    # An optional name for the participant. Provides the model information to differentiate between participants of the same role.
    string name?;
|};

# System chat message record
public type ChatSystemMessage record {|
    # Role of the message
    SYSTEM role;
    # Content of the message
    string content;
    # An optional name for the participant. Provides the model information to differentiate between participants of the same role.
    string name?;
|};

# Assistant chat message record
public type ChatAssistantMessage record {|
    # Role of the message
    ASSISTANT role;
    # The contents of the assistant message. Required unless `tool_calls` or `function_call` is specified.
    string? content?;
    # An optional name for the participant. Provides the model information to differentiate between participants of the same role.
    string name?;
    # The function calls generated by the model, such as function calls.
    FunctionCall function_call?;
|};

// # Function message record
public type ChatFunctionMessage record {|
    # Role of the message
    FUNCTION role;
    # Content of the message
    string? content = ();
    # Name of the function when the message is a function call
    string name;
|};

public type ChatMessage ChatUserMessage|ChatSystemMessage|ChatAssistantMessage|ChatFunctionMessage;

# Function definitions for function calling API.
public type ChatCompletionFunctions record {|
    # Name of the function
    string name;
    # Description of the function
    string description;
    # Parameters of the function
    JsonInputSchema parameters?;
|};

# Function call record
public type FunctionCall record {|
    # Name of the function
    string name;
    # Arguments of the function
    string arguments;
|};

# Extendable LLM model object that can be used for completion tasks.
# Useful to initialize the agents.
public type LlmModel distinct isolated object {
};

# Extendable LLM model object for completion models.
public type CompletionLlmModel distinct isolated object {
    *LlmModel;
    public isolated function complete(string prompt, string? stop = ()) returns string|LlmError;
};

# Extendable LLM model object for chat LLM models
public type ChatLlmModel distinct isolated object {
    *LlmModel;
    public isolated function chatComplete(ChatMessage[] messages, string? stop = ()) returns string|LlmError;
};

# Extendable LLM model object for LLM models with function call API
public type FunctionCallLlmModel distinct isolated object {
    *LlmModel;
    public isolated function functionCall(ChatMessage[] messages, ChatCompletionFunctions[] functions, string? stop = ()) returns string|FunctionCall|LlmError;
};

public isolated class Gpt3Model {
    *CompletionLlmModel;
    final text:Client llmClient;
    public final CompletionModelConfig modelConfig;

    # Initializes the GPT-3 model with the given connection configuration and model configuration.
    #
    # + connectionConfig - Connection Configuration for OpenAI text client 
    # + modelConfig - Model Configuration for OpenAI text client
    # + return - Error if the model initialization fails
    public isolated function init(text:ConnectionConfig connectionConfig, CompletionModelConfig modelConfig = {}) returns error? {
        self.llmClient = check new (connectionConfig);
        self.modelConfig = modelConfig;
    }

    # Completes the given prompt using the GPT3 model.
    #
    # + prompt - Prompt to be completed
    # + stop - Stop sequence to stop the completion
    # + return - Completed prompt or error if the completion fails
    public isolated function complete(string prompt, string? stop = ()) returns string|LlmError {
        text:CreateCompletionResponse|error response = self.llmClient->/completions.post({
            ...self.modelConfig,
            stop,
            prompt
        });
        if response is error {
            return error LlmConnectionError("Error while connecting to the model", response);
        }
        return response.choices[0].text ?: error LlmInvalidResponseError("Empty response from the model");
    }
}

public isolated class AzureGpt3Model {
    *CompletionLlmModel;
    final azure_text:Client llmClient;
    public final CompletionModelConfig modelConfig;
    private final string deploymentId;
    private final string apiVersion;

    # Initializes the GPT-3 model with the given connection configuration and model configuration.
    #
    # + connectionConfig - Connection Configuration for Azure OpenAI text client
    # + serviceUrl - Service URL for Azure OpenAI service
    # + deploymentId - Deployment ID for Azure OpenAI model instance
    # + apiVersion - API version for Azure OpenAI model instance
    # + modelConfig - Model Configuration for Azure OpenAI text client
    # + return - Error if the model initialization fails
    public isolated function init(azure_text:ConnectionConfig connectionConfig, string serviceUrl, string deploymentId,
            string apiVersion, CompletionModelConfig modelConfig = {}) returns error? {
        self.llmClient = check new (connectionConfig, serviceUrl);
        self.modelConfig = modelConfig;
        self.deploymentId = deploymentId;
        self.apiVersion = apiVersion;
    }

    # Completes the given prompt using the GPT3 model.
    #
    # + prompt - Prompt to be completed
    # + stop - Stop sequence to stop the completion
    # + return - Completed prompt or error if the completion fails
    public isolated function complete(string prompt, string? stop = ()) returns string|LlmError {
        azure_text:Inline_response_200|error response = self.llmClient->/deployments/[self.deploymentId]/completions.post(self.apiVersion, {
            ...self.modelConfig,
            stop,
            prompt
        });
        if response is error {
            return error LlmConnectionError("Error while connecting to the model", response);
        }
        return response.choices[0].text ?: error LlmInvalidResponseError("Empty response from the model");
    }
}

public isolated class ChatGptModel {
    *FunctionCallLlmModel;
    *ChatLlmModel;
    final chat:Client llmClient;
    public final ChatModelConfig modelConfig;

    # Initializes the ChatGPT model with the given connection configuration and model configuration.
    #
    # + connectionConfig - Connection Configuration for OpenAI chat client
    # + modelConfig - Model Configuration for OpenAI chat client
    # + return - Error if the model initialization fails
    public isolated function init(chat:ConnectionConfig connectionConfig, ChatModelConfig modelConfig = {}) returns error? {
        self.llmClient = check new (connectionConfig);
        self.modelConfig = modelConfig;
    }

    # Completes the given prompt using the ChatGPT model.
    #
    # + messages - Messages to be completed
    # + stop - Stop sequence to stop the completion
    # + return - Completed message or error if the completion fails
    public isolated function chatComplete(ChatMessage[] messages, string? stop = ()) returns string|LlmError {
        chat:CreateChatCompletionResponse|error response = self.llmClient->/chat/completions.post({
            ...self.modelConfig,
            stop,
            messages
        });
        if response is error {
            return error LlmConnectionError("Error while connecting to the model", response);
        }
        chat:ChatCompletionResponseMessage? message = response.choices[0].message;
        string? content = message?.content;
        return content ?: error LlmInvalidResponseError("Empty response from the model");
    }

    # Uses function call API to determine next function to be called
    #
    # + messages - List of chat messages 
    # + functions - Function definitions to be used for the function call
    # + stop - Stop sequence to stop the completion
    # + return - Function to be called, chat response or an error in-case of failures
    public isolated function functionCall(ChatMessage[] messages, ChatCompletionFunctions[] functions, string? stop = ()) returns string|FunctionCall|LlmError {

        chat:CreateChatCompletionResponse|error response = self.llmClient->/chat/completions.post({
            ...self.modelConfig,
            stop,
            messages,
            functions
        });
        if response is error {
            return error LlmConnectionError("Error while connecting to the model", response);
        }
        chat:ChatCompletionResponseMessage? message = response.choices[0].message;
        string? content = message?.content;
        if content is string {
            return content;
        }
        chat:ChatCompletionRequestAssistantMessage_function_call? 'function = message?.function_call;
        if 'function is chat:ChatCompletionRequestAssistantMessage_function_call {
            return {
                ...'function
            };
        }
        return error LlmInvalidResponseError("Empty response from the model when using function call API");
    }
}

public isolated class AzureChatGptModel {
    *FunctionCallLlmModel;
    *ChatLlmModel;
    final azure_chat:Client llmClient;
    public final ChatModelConfig modelConfig;
    private final string deploymentId;
    private final string apiVersion;

    # Initializes the ChatGPT model with the given connection configuration and model configuration.
    #
    # + connectionConfig - Connection Configuration for OpenAI chat client
    # + serviceUrl - Service URL for Azure OpenAI service
    # + deploymentId - Deployment ID for Azure OpenAI model instance
    # + apiVersion - API version for Azure OpenAI model instance
    # + modelConfig - Model Configuration for OpenAI chat client
    # + return - Error if the model initialization fails
    public isolated function init(azure_chat:ConnectionConfig connectionConfig, string serviceUrl, string deploymentId,
            string apiVersion, ChatModelConfig modelConfig = {}) returns error? {
        self.llmClient = check new (connectionConfig, serviceUrl);
        self.modelConfig = modelConfig;
        self.deploymentId = deploymentId;
        self.apiVersion = apiVersion;
    }

    # Completes the given prompt using the ChatGPT model.
    #
    # + messages - Messages to be completed
    # + stop - Stop sequence to stop the completion
    # + return - Completed message or error if the completion fails
    public isolated function chatComplete(ChatMessage[] messages, string? stop = ()) returns string|LlmError {
        azure_chat:CreateChatCompletionResponse|error response = self.llmClient->/deployments/[self.deploymentId]/chat/completions.post(self.apiVersion, {
            ...self.modelConfig,
            stop,
            messages
        });
        if response is error {
            return error LlmConnectionError("Error while connecting to the model", response);
        }
        string? content = ();
        record {|azure_chat:ChatCompletionResponseMessage message?; azure_chat:ContentFilterChoiceResults content_filter_results?; int index?; string finish_reason?; anydata...;|}[]? choices = response.choices;
        if choices !is () {
            content = choices[0].message?.content;
        }
        return content ?: error LlmInvalidResponseError("Empty response from the model");
    }

    # Uses function call API to determine next function to be called
    #
    # + messages - List of chat messages 
    # + functions - Function definitions to be used for the function call
    # + stop - Stop sequence to stop the completion
    # + return - Function to be called, chat response or an error in-case of failures
    public isolated function functionCall(ChatMessage[] messages, ChatCompletionFunctions[] functions, string? stop = ()) returns string|FunctionCall|LlmError {
        azure_chat:CreateChatCompletionResponse|error response =
    self.llmClient->/deployments/[self.deploymentId]/chat/completions.post(self.apiVersion, {
            ...self.modelConfig,
            stop,
            messages,
            functions
        });
        if response is error {
            return error LlmConnectionError("Error while connecting to the model", response);
        }

        record {|azure_chat:ChatCompletionResponseMessage message?; azure_chat:ContentFilterChoiceResults content_filter_results?; int index?; string finish_reason?; anydata...;|}[]? choices = response.choices;
        if choices !is () {
            // check whether the model response is text
            string? content = choices[0].message?.content;
            if content is string {
                return content;
            }

            // check whether the model response is a function call
            azure_chat:ChatCompletionFunctionCall? function_call = choices[0].message?.function_call;
            if function_call is azure_chat:ChatCompletionFunctionCall {
                return {
                    ...function_call
                };
            }
        }
        return error LlmInvalidResponseError("Empty response from the model when using function call API");
    }
}

