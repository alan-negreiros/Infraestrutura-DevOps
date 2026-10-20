import { HealthController } from "../../src/controllers/HealthController";
import { redis } from "../../src/config/redis";
import { AppDataSource } from "../../src/config/database";

jest.mock("../../src/config/redis", () => ({
  redis: {
    ping: jest.fn(),
  },
}));

jest.mock("../../src/config/database", () => ({
  AppDataSource: {
    isInitialized: true,
    query: jest.fn(),
  },
}));

function mockResponse() {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
}

describe("HealthController", () => {
  const controller = new HealthController();

  beforeEach(() => {
    jest.spyOn(console, "error").mockImplementation(() => undefined);
    (AppDataSource as any).isInitialized = true;
  });

  it("should report liveness", () => {
    const res = mockResponse();

    controller.liveness({} as any, res);

    expect(res.status).toHaveBeenCalledWith(200);
    expect(res.json).toHaveBeenCalledWith({ status: "ok" });
  });

  it("should report ready when database and redis respond", async () => {
    (AppDataSource.query as jest.Mock).mockResolvedValue([{ "?column?": 1 }]);
    (redis.ping as jest.Mock).mockResolvedValue("PONG");
    const res = mockResponse();

    await controller.readiness({} as any, res);

    expect(AppDataSource.query).toHaveBeenCalledWith("SELECT 1");
    expect(redis.ping).toHaveBeenCalledTimes(1);
    expect(res.status).toHaveBeenCalledWith(200);
  });

  it("should report unavailable when redis is down", async () => {
    (AppDataSource.query as jest.Mock).mockResolvedValue([]);
    (redis.ping as jest.Mock).mockRejectedValue(new Error("Connection refused"));
    const res = mockResponse();

    await controller.readiness({} as any, res);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith({ status: "unavailable" });
  });

  it("should report unavailable when database is not initialized", async () => {
    (AppDataSource as any).isInitialized = false;
    const res = mockResponse();

    await controller.readiness({} as any, res);

    expect(AppDataSource.query).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(503);
  });
});
