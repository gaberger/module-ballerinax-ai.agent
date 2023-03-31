import ballerina/io;
import ballerina/regex;

public type Parameters record {
};

public type Action record {|
    string name;
    string description;
    Parameters? params;
    function func;
|};

public type LLMResponse record {|
    string action;
    json actionInput;
    string thought;
    boolean finalThought;
|};

# Agent implementation to perform actions with LLMs to add
# computational power and knowledge to the LLMs
public class Agent {

    private string prompt;
    private map<Action> actions;
    private LLMModel model;

    # Initialize an Agent
    #
    # + model - LLM model instance
    public function init(LLMModel model) {
        self.prompt = "";
        self.actions = {};
        self.model = model;
    }

    # Register actions to the agent. 
    # These actions will be by the LLM to perform tasks 
    #
    # + actions - A list of actions that are available to the LLM
    public function registerActions(Action... actions) {
        foreach Action action in actions {
            self.actions[action.name] = action;
        }
    }

    # Build description for an action to generate prompts to the LLMs
    #
    # + action - action requires prompt decription
    # + return - prompt description generated for the action
    private function buildActionDescription(Action action) returns string {
        if action.params == null { // case for functions with zero parameters 
            return string `${action.name}: ${action.description}. Parameters should be empty {}`;
        }
        return string `${action.name}: ${action.description}. Parameters to this tool should be in the format of ${action.params.toString()}`;
    }

    # Initialize the prompt during a single run for a given user query
    #
    # + query - user's query
    private function initializaPrompt(string query) {
        string[] toolDescriptionList = [];
        string[] toolNameList = [];
        foreach Action action in self.actions {
            toolNameList.push(action.name);
            toolDescriptionList.push(self.buildActionDescription(action));
        }
        string toolDescriptions = string:'join("\n", ...toolDescriptionList);
        string toolNames = toolNameList.toString();

        string promptTemplate = string `
Answer the following questions as best you can without making any assumptions. You have access to the following tools: 

${toolDescriptions}

Use the following format:
Question: the input question you must answer
Thought: you should always think about what to do
Action: the action to take, should be one of ${toolNames}.
Action Input: the input to the action
Observation: the result of the action
... (this Thought/Action/Action Input/Observation can repeat N times)
Thought: I now know the final answer
Final Answer: the final answer to the original input question

Begin!

${query}
Thought:`;

        self.prompt = promptTemplate.trim(); // reset the prompt during each run
    }

    # Build the prompts during each decision iterations 
    #
    # + thoughts - thoughts by the model during the previous iterations
    # + observation - observations returned by the performed action
    private function buildNextPrompt(string thoughts, string observation) {

        self.prompt = string `${self.prompt} ${thoughts}
Observation: ${observation}
Thought:`;

    }

    # Use LLMs to decide the next action 
    # + return - decision by the LLM or an error if call to the LLM fails
    private function decideNextAction() returns string?|error {
        return self.model.complete(self.prompt);
    }

    # Parse the LLM response in string form to an LLMResponse record
    #
    # + rawResponse - string form LLM response including new action 
    # + return - LLMResponse record or an error if the parsing failed
    private function parseLLMResponse(string rawResponse) returns LLMResponse|error {
        string replaceChar = "=";
        string splitChar = ":";
        string[] content = regex:split(rawResponse, "\n");
        string thought = content[0].trim();
        if content.length() == FINAL_THOUGHT_LINE_COUNT {
            return {
                thought: thought,
                action: content[1].trim(),
                actionInput: null,
                finalThought: true
            };
        }
        if content.length() == REGULAR_THOUGHT_LINE_COUNT {
            json actionInput = check regex:split(regex:replace(content[2], splitChar, replaceChar), replaceChar).pop().fromJsonString();
            return {
                thought: thought,
                action: regex:split(content[1], splitChar).pop().trim(),
                actionInput: actionInput,
                finalThought: false
            };
        }
        return error(string `Error while parsing LLM response: ${rawResponse}`);
    }

    # execute the action decided by the LLM 
    #
    # + llmResponse - Formated response record by the LLM
    # + return - string observation by the action or an error if the action fails 
    private function executeAction(LLMResponse llmResponse) returns string|error {
        if !(self.actions.hasKey(llmResponse.action)) {
            // TODO instead we can return string error to the LLM so it can correct its mistake
            return error(string `Found undefined action: ${llmResponse.action}`);
        }
        Action action = self.actions.get(llmResponse.action);

        map<json> & readonly actionInput = check llmResponse.actionInput.fromJsonWithType();

        // try to execute the action
        any|error observation;
        if actionInput.length() > 0 {
            observation = function:call(action.func, actionInput);
        } else {
            observation = function:call(action.func);
        }

        if (observation is error) {
            return observation.message();
        }
        return observation.toString();

    }

    # Execute the agent for a given user's query
    #
    # + query - natural langauge commands to the agent
    # + maxIter - no. of max iterations that agent will run to execute the task
    # + return - returns error, in case of a failure
    public function run(string query, int maxIter = 5) returns error? {
        self.initializaPrompt(query);

        int iter = 0;
        LLMResponse action;
        while maxIter > iter {

            string? response = check self.decideNextAction();
            if !(response is string) {
                io:println(string `Model returns invalid response: ${response.toString()}`);
                break;
            }
            string currentThought = response.toString().trim();

            io:println("\n\nReasoning iteration: " + iter.toString());
            io:println("Thought: " + currentThought);

            action = check self.parseLLMResponse(currentThought);
            if action.finalThought {
                break;
            }

            string currentObservation = check self.executeAction(action);
            self.buildNextPrompt(currentThought, currentObservation);
            iter = iter + 1;

            io:println("Observation: " + currentObservation);
        }
    }
}
