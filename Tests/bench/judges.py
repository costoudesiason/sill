"""The benchmarks' own judges, prompts copied word for word, run on Claude.

- WebJudge (Online-Mind2Web, OSU NLP: github.com/OSU-NLP-Group/Online-Mind2Web,
  src/methods/webjudge_online_mind2web.py): key points from the task, every screenshot of the
  run scored 1-5 against them, then a strict verdict from the action history and the
  screenshots that scored 3 or more. The paper uses o4-mini; here it's a Claude model.
- WebVoyager's auto-evaluator (src/methods/webvoyager_eval.py, the same as WebVoyager's
  auto_eval.py): the task, the agent's answer, and the last screenshots; the screenshots win
  when they contradict the answer.

The judge model is gpt-5.6-luna by default (BU Bench's own judge model), so no Claude grades Claude.

The screenshots come from the run's trace (sill-mcp with SILL_TRACE_DIR): one after every
action, taken by the harness, never shown to the agent. The judge sees what the page showed,
not what the agent said it showed."""
import base64, concurrent.futures, json, os, re, subprocess, time

MAX_IMAGE = 50

KEY_POINTS_SYSTEM = """You are an expert tasked with analyzing a given task to identify the key points explicitly stated in the task description.

**Objective**: Carefully analyze the task description and extract the critical elements explicitly mentioned in the task for achieving its goal.

**Instructions**:
1. Read the task description carefully.
2. Identify and extract **key points** directly stated in the task description.
   - A **key point** is a critical element, condition, or step explicitly mentioned in the task description.
   - Do not infer or add any unstated elements.
   - Words such as "best," "highest," "cheapest," "latest," "most recent," "lowest," "closest," "highest-rated," "largest," and "newest" must go through the sort function(e.g., the key point should be "Filter by highest").

**Respond with**:
- **Key Points**: A numbered list of the explicit key points for completing this task, one per line, without explanations or additional details."""

IMAGE_SYSTEM = """You are an expert evaluator tasked with determining whether an image contains information about the necessary steps to complete a task.

**Objective**: Analyze the provided image and decide if it shows essential steps or evidence required for completing the task. Use your reasoning to explain your decision before assigning a score.

**Instructions**:
1. Provide a detailed description of the image, including its contents, visible elements, text (if any), and any notable features.

2. Carefully examine the image and evaluate whether it contains necessary steps or evidence crucial to task completion:
- Identify key points that could be relevant to task completion, such as actions, progress indicators, tool usage, applied filters, or step-by-step instructions.
- Does the image show actions, progress indicators, or critical information directly related to completing the task?
- Is this information indispensable for understanding or ensuring task success?
- If the image contains partial but relevant information, consider its usefulness rather than dismissing it outright.

3. Provide your response in the following format:
- **Reasoning**: Explain your thought process and observations. Mention specific elements in the image that indicate necessary steps, evidence, or lack thereof.
- **Score**: Assign a score based on the reasoning, using the following scale:
    - **1**: The image does not contain any necessary steps or relevant information.
    - **2**: The image contains minimal or ambiguous information, unlikely to be essential.
    - **3**: The image includes some relevant steps or hints but lacks clarity or completeness.
    - **4**: The image contains important steps or evidence that are highly relevant but not fully comprehensive.
    - **5**: The image clearly displays necessary steps or evidence crucial for completing the task.

Respond with:
1. **Reasoning**: [Your explanation]
2. **Score**: [1-5]"""

FINAL_SYSTEM = """You are an expert in evaluating the performance of a web navigation agent. The agent is designed to help a human user navigate a website to complete a task. Given the user's task, the agent's action history, key points for task completion, some potentially important web pages in the agent's trajectory and their reasons, your goal is to determine whether the agent has completed the task and achieved all requirements.

Your response must strictly follow the following evaluation criteria!
*Important Evaluation Criteria*:
1: The filtered results must be displayed correctly. If filters were not properly applied (i.e., missing selection, missing confirmation, or no visible effect in results), the task is not considered successful.
2: You must carefully check whether these snapshots and action history meet these key points. Ensure that specific filter conditions, such as "best," "highest," "cheapest," "latest," "most recent," "lowest," "closest," "highest-rated," "largest," and "newest" are correctly applied using the filter function(e.g., sort function).
3: Certain key points or requirements should be applied by the filter. Otherwise, a search with all requirements as input will be deemed a failure since it cannot guarantee that all results meet the requirements!
4: If the task requires filtering by a specific range of money, years, or the number of beds and bathrooms, the applied filter must exactly match the given requirement. Any deviation results in failure. To ensure the task is successful, the applied filter must precisely match the specified range without being too broad or too narrow.
Examples of Failure Cases:
- If the requirement is less than $50, but the applied filter is less than $25, it is a failure.
- If the requirement is $1500-$2500, but the applied filter is $2000-$2500, it is a failure.
- If the requirement is $25-$200, but the applied filter is $0-$200, it is a failure.
- If the required years are 2004-2012, but the filter applied is 2001-2012, it is a failure.
- If the required years are before 2015, but the applied filter is 2000-2014, it is a failure.
- If the task requires exactly 2 beds, but the filter applied is 2+ beds, it is a failure.
5: Some tasks require a submission action or a display of results to be considered successful.
6: If the retrieved information is invalid or empty(e.g., No match was found), but the agent has correctly performed the required action, it should still be considered successful.
7: If the current page already displays all available items, then applying a filter is not necessary. As long as the agent selects items that meet the requirements (e.g., the cheapest or lowest price), the task is still considered successful.

*IMPORTANT*
Format your response into two lines as shown below:

Thoughts: <your thoughts and reasoning process based on double-checking each key points and the evaluation criteria>
Status: "success" or "failure"
"""

WEBVOYAGER_SYSTEM = """As an evaluator, you will be presented with three primary components to assist you in your role:

1. Web Task Instruction: This is a clear and specific directive provided in natural language, detailing the online activity to be carried out. These requirements may include conducting searches, verifying information, comparing prices, checking availability, or any other action relevant to the specified web service (such as Amazon, Apple, ArXiv, BBC News, Booking etc).

2. Result Screenshots: This is a visual representation of the screen showing the result or intermediate state of performing a web task. It serves as visual proof of the actions taken in response to the instruction.

3. Result Response: This is a textual response obtained after the execution of the web task. It serves as textual result in response to the instruction.

-- You DO NOT NEED to interact with web pages or perform actions such as booking flights or conducting searches on websites.
-- You SHOULD NOT make assumptions based on information not presented in the screenshot when comparing it to the instructions.
-- Your primary responsibility is to conduct a thorough assessment of the web task instruction against the outcome depicted in the screenshot and in the response, evaluating whether the actions taken align with the given instructions.
-- NOTE that the instruction may involve more than one task, for example, locating the garage and summarizing the review. Failing to complete either task, such as not providing a summary, should be considered unsuccessful.
-- NOTE that the screenshot is authentic, but the response provided by LLM is generated at the end of web browsing, and there may be discrepancies between the text and the screenshots.
-- Note the difference: 1) Result response may contradict the screenshot, then the content of the screenshot prevails, 2) The content in the Result response is not mentioned on the screenshot, choose to believe the content.

You should elaborate on how you arrived at your final evaluation and then provide a definitive verdict on whether the task has been successfully accomplished, either as 'SUCCESS' or 'FAILURE'."""


class Claude:
    """One message in, one answer out, through the claude CLI (no tools, no MCP). Models that
    aren't Claude go through the user's ~/.claude config (claude-code-proxy, their Codex sign-in)."""
    def __init__(self, binary, env, model, cwd, effort=None):
        self.binary, self.env, self.model, self.cwd, self.effort = binary, env, model, cwd, effort
        if not model.startswith("claude"):
            self.env = {**env, "CLAUDE_CONFIG_DIR": os.path.expanduser("~/.claude")}

    def ask(self, system, content, timeout=300):
        argv = [self.binary, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--model", self.model, "--system-prompt", system, "--tools", "", "--strict-mcp-config",
                "--mcp-config", '{"mcpServers":{}}', "--disable-slash-commands", "--no-session-persistence", "--max-turns", "1"]
        if self.effort: argv += ["--effort", self.effort]
        text = json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"
        for attempt in range(3):
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env, cwd=self.cwd)
            try: out, _ = p.communicate(text, timeout=timeout)
            except subprocess.TimeoutExpired:
                p.kill(); out, _ = p.communicate()
            for line in out.splitlines():
                try: e = json.loads(line)
                except ValueError: continue
                if e.get("type") == "result" and e.get("result"): return e["result"]
            time.sleep(3 * (attempt + 1))
        return ""


def picture(path):
    with open(path, "rb") as fh:
        return {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(fh.read()).decode()}}


def read_trace(folder):
    """The steps a run's trace holds, in order: action, screenshot path (or None), url."""
    steps = []
    try:
        for line in open(os.path.join(folder, "steps.jsonl")):
            try: s = json.loads(line)
            except ValueError: continue
            shot = os.path.join(folder, s["screenshot"]) if s.get("screenshot") else None
            steps.append({"action": s.get("action", ""), "shot": shot if shot and os.path.exists(shot) else None, "url": s.get("url", "")})
    except FileNotFoundError: pass
    return steps


def webjudge(claude, task, steps, answer, threshold=3, workers=8):
    """WebJudge, as the paper runs it. Returns (success, details)."""
    kp = claude.ask(KEY_POINTS_SYSTEM, [{"type": "text", "text": f"Task: {task}"}])
    kp = kp.replace("\n\n", "\n")
    try: kp = kp.split("**Key Points**:")[1]
    except IndexError: kp = kp.split("Key Points:")[-1]
    key_points = "\n".join(line.lstrip() for line in kp.splitlines())

    shots = [s["shot"] for s in steps if s["shot"]]
    def score(path):
        text = f"**Task**: {task}\n\n**Key Points for Task Completion**: {key_points}\n\nThe snapshot of the web page is shown in the image."
        r = claude.ask(IMAGE_SYSTEM, [{"type": "text", "text": text}, picture(path)])
        try:
            n = int(re.findall(r"[1-5]", r.split("Score")[1])[0])
            thought = r.split("**Reasoning**:")[-1].strip().lstrip("\n").split("\n\n")[0].replace("\n", " ")
        except (IndexError, ValueError):
            n, thought = 0, ""
        return n, thought
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        scored = list(pool.map(score, shots))
    kept = [(p, t) for p, (n, t) in zip(shots, scored) if n >= threshold][:MAX_IMAGE]
    actions = [s["action"] for s in steps]
    if answer: actions.append("Final answer: " + answer)
    history = "\n".join(f"{i + 1}. {a}" for i, a in enumerate(actions))
    if kept:
        thoughts = "\n".join(f"{i + 1}. {t}" for i, (_, t) in enumerate(kept) if t)
        text = f"User Task: {task}\n\nKey Points: {key_points}\n\nAction History:\n{history}\n\nThe potentially important snapshots of the webpage in the agent's trajectory and their reasons:\n{thoughts}"
    else:
        text = f"User Task: {task}\n\nKey Points: {key_points}\n\nAction History:\n{history}"
    verdict = claude.ask(FINAL_SYSTEM, [{"type": "text", "text": text}] + [picture(p) for p, _ in kept])
    try: ok = "success" in verdict.lower().split("status:")[1]
    except IndexError: ok = False
    return ok, {"key_points": key_points, "scores": [n for n, _ in scored], "kept": len(kept), "screenshots": len(shots), "verdict": verdict}


def webvoyager_judge(claude, task, steps, answer, k=3):
    """WebVoyager's auto-evaluator with the last k screenshots (k=3, as WebVoyager's paper)."""
    shots = [s["shot"] for s in steps if s["shot"]][-k:]
    text = f"TASK: {task}\n\nResult Response: {answer}\n\n{len(shots)} screenshots at the end: "
    verdict = claude.ask(WEBVOYAGER_SYSTEM, [{"type": "text", "text": text}] + [picture(p) for p in shots] + [{"type": "text", "text": "Your verdict:\n"}])
    return ("FAILURE" not in verdict and bool(verdict)), {"screenshots": len(shots), "verdict": verdict}
