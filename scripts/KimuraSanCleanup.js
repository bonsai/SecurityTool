module.exports = {
  name: "KimuraSanCleanup",
  description: "SecurityToolの拡張クリーンアップ機能（Docker/ML/Windows）を呼び出します。",
  parameters: {
    type: "object",
    properties: {
      target: {
        type: "string",
        description: "クリーンアップ対象を指定します。",
        enum: ["docker", "models", "windows_extra", "all"]
      },
      dryrun: {
        type: "boolean",
        description: "プレビューのみ実行するかどうか。",
        default: true
      },
      confirm: {
        type: "boolean",
        description: "対話的に確認しながら実行するかどうか。",
        default: true
      }
    },
    required: ["target"]
  },
  async execute({ target = "all", dryrun = true, confirm = true }) {
    const { exec } = require("child_process");
    // 注意: このパスは実行環境に合わせて修正する必要があります。
    const scriptPath = "C:\\path\\to\\SecurityTool\\scripts\\SecurityTool.ps1";
    
    const args = [
        `-Action cleanup`,
        `-Target ${target}`,
        dryrun ? "-DryRun" : "",
        confirm ? "-Confirm" : ""
    ].filter(Boolean).join(" ");

    const cmd = `powershell -File ${scriptPath} ${args}`;

    return new Promise((resolve, reject) => {
      exec(cmd, { shell: "powershell.exe" }, (error, stdout, stderr) => {
        if (error) {
          console.error(`exec error: ${error}`);
          return reject(stderr || error.message);
        }
        resolve({ output: stdout });
      });
    });
  }
};
