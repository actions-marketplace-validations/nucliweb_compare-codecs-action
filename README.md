# Compare image codecs

A GitHub Action that compares **JPEG XL, AVIF, WebP, jpegli, mozjpeg and HEIC** on your own images at **equal perceptual quality**, and can fail a pull request when a codec's output grows or loses quality against a committed baseline.

Each codec's quality knob is searched until the decoded image reaches the same [ssimulacra2](https://github.com/cloudinary/ssimulacra2) score, so the comparison reads file size at equal quality instead of each codec's own, non-equivalent quality scale. The action runs [`compare-codecs`](https://github.com/nucliweb/image-tools/tree/main/compare) from the [image-tools](https://github.com/nucliweb/image-tools) container, whose pinned codec versions make sizes reproducible from run to run.

## Usage

```yaml
- uses: actions/checkout@v7
- uses: nucliweb/compare-codecs-action@v1
  with:
    images: assets/photos
    target: 90
```

The table goes to the job summary, and the CSV and the interactive HTML report are written to `codec-comparison/`. Upload them to keep them:

```yaml
- id: compare
  uses: nucliweb/compare-codecs-action@v1
  with:
    images: assets/photos
- uses: actions/upload-artifact@v7
  with:
    name: codec-comparison
    path: codec-comparison/
```

### Rate-distortion

`rd` searches every codec at each target in a list and reports the bpp at each one, plus the **BD-rate** against mozjpeg: the average difference in bits at equal quality across the range (`-30%` means 30% fewer bits for the same score).

```yaml
- uses: nucliweb/compare-codecs-action@v1
  with:
    images: assets/photos
    rd: 70,80,85,90,95
```

### Opt-in variants

Beside the six formats, five variants each change one encoder setting, so a comparison can show what that setting is worth on your images: `webp-sharp` (WebP with sharp RGB→YUV conversion), `heic-444` (HEIC with full-resolution chroma), `avif-rav1e` and `avif-svt` (AVIF encoded by rav1e or SVT-AV1 instead of aom) and `jpeg-turbo` (plain libjpeg-turbo). Name them in `codecs`, or use `all`:

```yaml
- uses: nucliweb/compare-codecs-action@v1
  with:
    images: assets/photos
    codecs: webp,webp-sharp,heic,heic-444
```

What each one changes, with measurements and references, is in the [image-tools documentation](https://github.com/nucliweb/image-tools/blob/main/compare/README.md#opt-in-variants).

### Regression gate

With a `baseline`, the step fails when a codec's bytes at equal quality grow more than `tolerance` (2%) or its ssimulacra2 score drops more than `quality-tolerance` (0.5) for any image, so a change to your images or pipeline that makes the output larger, or smaller at a lower quality, is caught.

```yaml
- uses: nucliweb/compare-codecs-action@v1
  with:
    images: assets/photos
    target: 90
    baseline: .github/codec-baseline.json
```

Generate the baseline from a run's `results.csv` with the same image version and target, and commit it. Sizes differ slightly between architectures, so generate it from a CSV produced on the same runner architecture (GitHub's `ubuntu-latest` is amd64):

```bash
docker run --rm -v "$PWD:/work" -w /work --entrypoint node ghcr.io/nucliweb/image-tools:0.4.0 \
  /opt/image-tools/compare/bin/check-regression.js .github/codec-baseline.json results.csv --update --target 90
```

Set `fail-on-regression: false` to only report it through the `regressed` output, for example to post a comment before failing:

```yaml
- id: compare
  uses: nucliweb/compare-codecs-action@v1
  with:
    images: assets/photos
    baseline: .github/codec-baseline.json
    fail-on-regression: false
- if: steps.compare.outputs.regressed == 'true'
  run: |
    gh pr comment "${{ github.event.pull_request.number }}" --body-file codec-comparison/regression.txt
    exit 1
  env:
    GH_TOKEN: ${{ github.token }}
```

Commenting needs `pull-requests: write` in the workflow's permissions; the action itself needs no token.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `images` | required | PNG files or directories of PNGs, relative to the workspace, one per line |
| `target` | `90` | Target ssimulacra2 score |
| `rd` | | Comma-separated targets for rate-distortion mode; replaces `target` |
| `codecs` | the six formats | Comma-separated subset of `jxl,avif,webp,jpegli,mozjpeg,heic`, plus the [opt-in variants](#opt-in-variants); `all` runs every codec and variant |
| `effort` | codec default | Matched encoder effort 0..10 (jxl, avif, webp) |
| `html` | `true` | Write the interactive HTML report (not in rate-distortion mode) |
| `html-max-dim` | tool default | Downscale images embedded in the report above this size |
| `baseline` | | Baseline JSON; enables the regression gate (single target only) |
| `tolerance` | `0.02` | Fractional size growth allowed against the baseline |
| `quality-tolerance` | `0.5` | ssimulacra2 points a score may drop against the baseline |
| `fail-on-regression` | `true` | Fail the step on a regression |
| `output-dir` | `codec-comparison` | Where the CSV, report and text output go |
| `image-version` | `0.4.0` | Tag of `ghcr.io/nucliweb/image-tools`, which pins the codec versions |

## Outputs

| Output | Description |
| --- | --- |
| `csv` | Path to the results CSV |
| `report` | Path to the HTML report, empty when none was written |
| `regressed` | `true` when the baseline gate found a regression, otherwise `false` |

A codec that fails on an image (an encoder that rejects the input, such as SVT-AV1 with odd dimensions) does not stop the run: its CSV row has empty metrics and the encoder's message in the `error` column, and with a `baseline` it counts as missing, which fails the gate.

`output-dir` also holds `comparison.txt` (the printed tables) and, with a baseline, `regression.txt`.

## Requirements

- A Linux runner with Docker, such as `ubuntu-latest` or `ubuntu-24.04-arm`. The image is published for amd64 and arm64.
- Input images are PNG in sRGB. Encoding at many quality points is CPU-bound: expect about a minute per megapixel image for all six codecs at one target, and one search per target in rate-distortion mode.

## License

MIT
