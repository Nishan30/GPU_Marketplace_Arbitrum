import express, { Request, Response } from 'express';

const app = express();
const PORT = process.env.PORT || 3001;

app.use(express.json());

interface JobRequestBody {
  jobId: string;
  cid:    string;
  seed:   string;
}

// Use the <Params, ResBody, ReqBody> generics as before:
app.post<{}, { message: string; jobId: string }, JobRequestBody>(
  '/receive-job',
  (req, res) => {
    const { jobId, cid, seed } = req.body;

    if (!jobId || !cid || !seed) {
      res.status(400).json({
        message: 'Missing job data (jobId, cid, or seed)',
        jobId: '',
      });
      return;  // <— stops execution, but returns void
    }

    console.log(`Acknowledging job ${jobId}. Seed: ${seed}`);

    res.status(200).json({
      message: 'Job acknowledged by stub provider',
      jobId,
    });
    // no `return res…` here
  }
);

app.listen(PORT, () => {
  console.log(`Listening on port ${PORT}`);
});
