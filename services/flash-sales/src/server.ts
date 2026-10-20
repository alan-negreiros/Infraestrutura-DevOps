import { app } from "./app";
import { AppDataSource } from "./config/database";
import { redis } from "./config/redis";

const PORT = process.env.PORT || 3000;
const SHUTDOWN_TIMEOUT_MS = parseInt(process.env.SHUTDOWN_TIMEOUT_MS || "10000");

AppDataSource.initialize()
  .then(() => {
    console.log("Data Source has been initialized!");
    const server = app.listen(PORT, () => {
      console.log(`Server is running on port ${PORT}`);
    });

    const shutdown = (signal: string) => {
      console.log(`${signal} received, shutting down gracefully`);
      setTimeout(() => process.exit(1), SHUTDOWN_TIMEOUT_MS).unref();
      server.close(async () => {
        await AppDataSource.destroy();
        await redis.quit();
        process.exit(0);
      });
    };

    process.once("SIGTERM", () => shutdown("SIGTERM"));
    process.once("SIGINT", () => shutdown("SIGINT"));
  })
  .catch((err) => {
    console.error("Error during Data Source initialization:", err);
    process.exit(1);
  });
