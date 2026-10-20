import { Request, Response } from "express";
import { AppDataSource } from "../config/database";
import { redis } from "../config/redis";

export class HealthController {
  liveness(req: Request, res: Response): Response {
    return res.status(200).json({ status: "ok" });
  }

  async readiness(req: Request, res: Response): Promise<Response> {
    try {
      if (!AppDataSource.isInitialized) {
        throw new Error("Database not initialized");
      }
      await AppDataSource.query("SELECT 1");
      await redis.ping();
      return res.status(200).json({ status: "ready" });
    } catch (error: any) {
      console.error("Readiness check failed:", error.message);
      return res.status(503).json({ status: "unavailable" });
    }
  }
}
