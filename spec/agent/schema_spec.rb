# frozen_string_literal: true

RSpec.describe ReconEngine::Agent::Schema do
  let(:tools) { ReconEngine::Agent::Tools::NAMES }

  def parse(raw)
    described_class.parse_step(raw, tool_names: tools)
  end

  describe "tool calls" do
    it "accepts a well-formed tool call" do
      step, errors = parse(FakeLLM.tool_call("get_schema", { "source" => "ledger" }))

      expect(errors).to be_empty
      expect(step["action"]).to eq("use_tool")
      expect(step["tool"]).to eq("get_schema")
    end

    it "rejects a tool that does not exist" do
      _step, errors = parse(FakeLLM.tool_call("drop_table"))

      expect(errors.first).to include("drop_table")
    end

    it "defaults missing arguments to an empty object" do
      step, errors = parse(JSON.generate({ "action" => "use_tool", "tool" => "get_schema" }))

      expect(errors).to be_empty
      expect(step["arguments"]).to eq({})
    end

    it "infers the action when the model omits it but names a tool" do
      step, errors = parse(JSON.generate({ "tool" => "get_schema", "arguments" => {} }))

      expect(errors).to be_empty
      expect(step["action"]).to eq("use_tool")
    end
  end

  describe "classifications" do
    it "accepts a well-formed classification" do
      step, errors = parse(FakeLLM.classification(classification: "ROUNDING"))

      expect(errors).to be_empty
      expect(step["classification"]).to eq("ROUNDING")
    end

    it "rejects a classification outside the enum" do
      _step, errors = parse(FakeLLM.classification(classification: "PROBABLY_FINE"))

      expect(errors.join).to include("classification")
    end

    it "rejects confidence outside 0..1" do
      _step, errors = parse(FakeLLM.classification(classification: "ROUNDING", confidence: 4))

      expect(errors.join).to include("confidence")
    end

    it "rejects empty or non-string evidence" do
      _step, errors = parse(FakeLLM.classification(classification: "ROUNDING", evidence: []))
      expect(errors.join).to include("evidence")

      _step, errors = parse(FakeLLM.classification(classification: "ROUNDING", evidence: [1, 2]))
      expect(errors.join).to include("evidence")
    end

    it "rejects a blank explanation" do
      _step, errors = parse(FakeLLM.classification(classification: "ROUNDING", explanation: "   "))

      expect(errors.join).to include("explanation")
    end

    it "collects every violation at once, so one repair prompt can fix them all" do
      _step, errors = parse(JSON.generate({
                                            "action" => "classify",
                                            "classification" => "NOPE",
                                            "confidence" => "high",
                                            "evidence" => "some text",
                                            "explanation" => "",
                                            "suggested_action" => nil
                                          }))

      expect(errors.length).to eq(5)
    end
  end

  describe "tolerating what models actually emit" do
    it "strips markdown code fences" do
      raw = "```json\n#{FakeLLM.classification(classification: "UNKNOWN")}\n```"
      step, errors = parse(raw)

      expect(errors).to be_empty
      expect(step["classification"]).to eq("UNKNOWN")
    end

    it "reports unparseable output as an error rather than raising" do
      step, errors = parse("I think this is probably a timing difference.")

      expect(step).to be_nil
      expect(errors.first).to include("not valid JSON")
    end

    it "rejects a JSON array" do
      step, errors = parse("[1, 2, 3]")

      expect(step).to be_nil
      expect(errors.first).to include("must be a JSON object")
    end
  end
end
