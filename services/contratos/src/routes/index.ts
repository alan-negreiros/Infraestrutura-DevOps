import { Router } from "express";
import { ContractController } from "../controllers/ContractController";
import { HealthController } from "../controllers/HealthController";
import { metricsController } from "../middlewares/metricsMiddleware";

const router = Router();
const contractController = new ContractController();
const healthController = new HealthController();

router.post("/contracts", (req, res, next) => contractController.handle(req, res).catch(next));
router.get("/metrics", metricsController);
router.get("/health", (req, res) => healthController.liveness(req, res));
router.get("/ready", (req, res, next) => healthController.readiness(req, res).catch(next));

export { router };
